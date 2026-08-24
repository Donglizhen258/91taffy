-- 91taffy.com 塔菲论坛抽奖：并发安全（2026-08-24）
-- 问题：draw_lottery_instant / _lottery_draw_core 里「已中奖人数」用 count 当兑换码下标，
--       两人同时抽会读到相同的 count，导致抽到同一奖项、甚至分配到同一个兑换码。
--       同理「剩余名额/剩余次数」的判断在并发下也会超发。
-- 方案：抽奖入口加 PostgreSQL advisory lock（pg_advisory_xact_lock），
--       按 post_id 串行化——同一帖子同一时刻只有一个抽奖事务在执行，
--       锁内读到的名额/兑换码下标一定是最新的，杜绝并发重复。
--       advisory xact lock 随事务结束自动释放，无需手动 unlock。
-- 运行方式：psycopg2 直连生产库执行。幂等可重复执行。

-- ============================================================
-- 1. 即时开奖：加 advisory lock 串行化
--    锁放在读 lottery 之前，保证锁内读到的 entry_count/winners 是最新
-- ============================================================
create or replace function public.draw_lottery_instant(p_post_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_lottery record;
  v_total_prizes integer := 0;
  v_won_count integer := 0;
  v_remaining_prizes integer;
  v_chances_left integer;
  v_entered_after integer;
  v_won boolean := false;
  v_prize_name text := '';
  v_prize_type text := '';
  v_code text := '';
  v_finished boolean := false;
  v_candidates jsonb := '[]';
  v_pick jsonb;
  v_prize_codes jsonb;
  v_this_prize_won integer;
begin
  if v_uid is null then
    raise exception '请先登录喵';
  end if;
  if not exists (select 1 from public.profiles p where p.id = v_uid and p.status = 'active') then
    raise exception '账号异常或被封禁，无法参与抽奖喵';
  end if;

  -- 串行化：同一帖子同一时刻只允许一个抽奖事务（防并发抽到同一奖项/同一兑换码）
  perform pg_advisory_xact_lock(hashtext(p_post_id::text));

  select * into v_lottery from public.forum_lotteries where post_id = p_post_id;
  if v_lottery.post_id is null then
    raise exception '这不是一个抽奖帖喵';
  end if;
  if v_lottery.draw_mode <> 'instant' then
    raise exception '该抽奖不是即时开奖模式喵';
  end if;
  if v_lottery.status <> 'drawing' then
    raise exception '该抽奖已结束喵';
  end if;
  -- 截止时间校验：已到期不能再抽
  if v_lottery.deadline is not null and v_lottery.deadline < now() then
    raise exception '该抽奖已截止喵';
  end if;
  -- 禁抽名单校验
  if exists (select 1 from public.forum_lottery_bans where post_id = p_post_id and user_id = v_uid) then
    raise exception '你已被禁止参与本次抽奖喵';
  end if;
  if exists (select 1 from public.forum_lottery_entries where post_id = p_post_id and user_id = v_uid)
     or exists (select 1 from public.forum_lottery_winners where post_id = p_post_id and user_id = v_uid) then
    raise exception '你已经参与过这个抽奖啦喵';
  end if;
  if v_lottery.entry_count >= v_lottery.max_entries then
    raise exception '该抽奖名额已抽完喵';
  end if;

  -- 占用一个参与名额
  insert into public.forum_lottery_entries (post_id, user_id)
  values (p_post_id, v_uid);
  update public.forum_lotteries
     set entry_count = entry_count + 1
   where post_id = p_post_id
  returning entry_count into v_entered_after;

  -- 统计：奖品总名额 & 已中奖人数
  select coalesce(sum((p->>'count')::int), 0)
    into v_total_prizes
    from jsonb_array_elements(v_lottery.prizes) as p
    where (p->>'count')::int >= 1;
  select count(*) into v_won_count
    from public.forum_lottery_winners where post_id = p_post_id;
  v_remaining_prizes := v_total_prizes - v_won_count;

  v_chances_left := v_lottery.max_entries - v_entered_after;

  if v_remaining_prizes > 0 then
    if v_chances_left <= 0 or v_remaining_prizes >= v_chances_left then
      v_won := true;
    else
      v_won := (random() < v_remaining_prizes::float / v_chances_left::float);
    end if;
  end if;

  if v_won then
    select coalesce(jsonb_agg(p), '[]'::jsonb)
      into v_candidates
      from jsonb_array_elements(v_lottery.prizes) as p
      where (p->>'count')::int >= 1
        and (p->>'type') in ('virtual','physical')
        and (select count(*) from public.forum_lottery_winners w
             where w.post_id = p_post_id and w.prize_name = p->>'name') < (p->>'count')::int;
    if jsonb_array_length(v_candidates) > 0 then
      v_pick := v_candidates->floor(random() * jsonb_array_length(v_candidates))::int;
      v_prize_name := v_pick->>'name';
      v_prize_type := v_pick->>'type';
      if v_prize_type = 'virtual' then
        v_prize_codes := coalesce(v_pick->'codes', '[]'::jsonb);
        select count(*) into v_this_prize_won
          from public.forum_lottery_winners
          where post_id = p_post_id and prize_name = v_prize_name;
        if jsonb_array_length(v_prize_codes) > v_this_prize_won then
          v_code := v_prize_codes->v_this_prize_won ->> 0;
        end if;
      end if;
      -- 虚拟奖品：中奖即视为已领取（兑换码直接展示）；实体奖品：待填联系方式领取
      if v_prize_type = 'virtual' then
        insert into public.forum_lottery_winners (post_id, user_id, prize_name, prize_type, code, claimed, claimed_at)
        values (p_post_id, v_uid, v_prize_name, v_prize_type, v_code, true, now());
      else
        insert into public.forum_lottery_winners (post_id, user_id, prize_name, prize_type, code)
        values (p_post_id, v_uid, v_prize_name, v_prize_type, v_code);
      end if;
    end if;
  end if;

  v_finished := (v_entered_after >= v_lottery.max_entries);
  if v_finished then
    update public.forum_lotteries
       set status = 'drawn', winner_count = (select count(*) from public.forum_lottery_winners where post_id = p_post_id)
     where post_id = p_post_id;
  end if;

  return jsonb_build_object(
    'won', v_won,
    'prize_name', v_prize_name,
    'prize_type', v_prize_type,
    'code', v_code,
    'entry_count', v_entered_after,
    'max_entries', v_lottery.max_entries,
    'finished', v_finished
  );
end;
$$;

-- ============================================================
-- 2. 定时开奖核心：加 advisory lock 串行化
-- ============================================================
create or replace function public._lottery_draw_core(p_post_id uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_lottery record;
  v_entrants uuid[];
  v_prize record;
  v_prize_codes jsonb;
  v_i integer;
  v_idx integer;
  v_pick uuid;
  v_code text;
  v_total_winners integer := 0;
begin
  -- 串行化：同一帖子同一时刻只允许一个开奖事务
  perform pg_advisory_xact_lock(hashtext(p_post_id::text));

  select * into v_lottery from public.forum_lotteries where post_id = p_post_id;
  if v_lottery.post_id is null then
    raise exception '这不是一个抽奖帖喵';
  end if;
  if v_lottery.status <> 'drawing' then
    raise exception '该抽奖已开奖或已结束喵';
  end if;

  select array_agg(user_id order by random())
    into v_entrants
    from public.forum_lottery_entries
    where post_id = p_post_id
      and not exists (
        select 1 from public.forum_lottery_bans b
        where b.post_id = p_post_id and b.user_id = forum_lottery_entries.user_id
      );
  if v_entrants is null or cardinality(v_entrants) = 0 then
    update public.forum_lotteries
       set status = 'drawn', winner_count = 0
     where post_id = p_post_id;
    return;
  end if;

  for v_prize in select * from jsonb_array_elements(v_lottery.prizes) with ordinality as p(v, idx)
    where (p.v->>'count')::int >= 1
  loop
    v_i := 0;
    v_prize_codes := coalesce(v_prize.v->'codes', '[]'::jsonb);
    while v_i < (v_prize.v->>'count')::int loop
      exit when cardinality(v_entrants) = 0;
      v_idx := 1 + floor(random() * cardinality(v_entrants))::int;
      v_pick := v_entrants[v_idx];
      v_entrants := v_entrants[1:v_idx-1] || v_entrants[v_idx+1:cardinality(v_entrants)];
      v_code := '';
      if v_prize.v->>'type' = 'virtual' and jsonb_array_length(v_prize_codes) > v_i then
        v_code := v_prize_codes->v_i ->> 0;
      end if;
      -- 虚拟奖品：中奖即视为已领取（兑换码直接展示）；实体奖品：待填联系方式领取
      if v_prize.v->>'type' = 'virtual' then
        insert into public.forum_lottery_winners (post_id, user_id, prize_name, prize_type, code, claimed, claimed_at)
        values (p_post_id, v_pick, v_prize.v->>'name', v_prize.v->>'type', v_code, true, now());
      else
        insert into public.forum_lottery_winners (post_id, user_id, prize_name, prize_type, code)
        values (p_post_id, v_pick, v_prize.v->>'name', v_prize.v->>'type', v_code);
      end if;
      v_total_winners := v_total_winners + 1;
      v_i := v_i + 1;
    end loop;
  end loop;

  update public.forum_lotteries
     set status = 'drawn', winner_count = v_total_winners
   where post_id = p_post_id;
end;
$$;

revoke execute on function public._lottery_draw_core(uuid) from anon, authenticated;

-- ============================================================
-- 3. 参与抽奖（定时模式）：同样加锁，避免并发下 entry_count 与 entries 不一致
-- ============================================================
create or replace function public.enter_lottery(p_post_id uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_status text;
  v_deadline timestamptz;
  v_draw_mode text;
  v_lottery_exists boolean;
begin
  if v_uid is null then
    raise exception '请先登录喵';
  end if;
  if not exists (select 1 from public.profiles p where p.id = v_uid and p.status = 'active') then
    raise exception '账号异常或被封禁，无法参与抽奖喵';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_post_id::text));

  select exists(select 1 from public.forum_lotteries where post_id = p_post_id)
    into v_lottery_exists;
  if not v_lottery_exists then
    raise exception '这不是一个抽奖帖喵';
  end if;
  select status, deadline, draw_mode into v_status, v_deadline, v_draw_mode
    from public.forum_lotteries where post_id = p_post_id;
  if v_draw_mode = 'instant' then
    raise exception '这是即时开奖抽奖，请直接点「立即抽」喵';
  end if;
  if v_status <> 'drawing' then
    raise exception '该抽奖已开奖或已结束，无法参与喵';
  end if;
  if v_deadline is not null and v_deadline < now() then
    raise exception '该抽奖已截止参与喵';
  end if;
  if exists (select 1 from public.forum_lottery_entries where post_id = p_post_id and user_id = v_uid) then
    raise exception '你已经参与过这个抽奖啦喵';
  end if;
  insert into public.forum_lottery_entries (post_id, user_id) values (p_post_id, v_uid);
  update public.forum_lotteries
     set entry_count = entry_count + 1
   where post_id = p_post_id;
end;
$$;

-- ============================================================
-- 3.1 maybe_auto_draw：加锁（scheduled 分支内部 _lottery_draw_core 已加锁，此处再包一层
--     保证「即时模式到期收尾」这个 update 也与抽奖串行，避免 winner_count 少算）
-- ============================================================
create or replace function public.maybe_auto_draw(p_post_id uuid)
returns boolean
language plpgsql security definer
set search_path = public
as $$
declare
  v_lottery record;
begin
  perform pg_advisory_xact_lock(hashtext(p_post_id::text));

  select * into v_lottery from public.forum_lotteries where post_id = p_post_id;
  if v_lottery.post_id is null then
    return false;
  end if;
  if v_lottery.status <> 'drawing'
     or v_lottery.deadline is null
     or v_lottery.deadline >= now() then
    return false;
  end if;
  if v_lottery.draw_mode = 'scheduled' then
    perform public._lottery_draw_core(p_post_id);
  else
    update public.forum_lotteries
       set status = 'drawn',
           winner_count = (select count(*) from public.forum_lottery_winners where post_id = p_post_id)
     where post_id = p_post_id;
  end if;
  return true;
end;
$$;

-- ============================================================
-- 3.2 finish_lottery_instant：加锁，与抽奖串行
-- ============================================================
create or replace function public.finish_lottery_instant(p_post_id uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_post_author uuid;
  v_lt_exists boolean;
  v_status text;
  v_draw_mode text;
begin
  if v_uid is null then
    raise exception '请先登录喵';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_post_id::text));

  select exists(select 1 from public.forum_lotteries where post_id = p_post_id) into v_lt_exists;
  if not v_lt_exists then
    raise exception '这不是一个抽奖帖喵';
  end if;
  select role into v_role from public.profiles where id = v_uid;
  select author_id into v_post_author from public.forum_posts where id = p_post_id;
  if v_role not in ('owner','admin') and (v_post_author is null or v_post_author <> v_uid) then
    raise exception '只有发起人或站长/管理员能结束抽奖喵';
  end if;
  select status, draw_mode into v_status, v_draw_mode
    from public.forum_lotteries where post_id = p_post_id;
  if v_status <> 'drawing' then
    raise exception '该抽奖已结束喵';
  end if;
  if v_draw_mode <> 'instant' then
    raise exception '该抽奖不是即时开奖模式喵';
  end if;
  update public.forum_lotteries
     set status = 'drawn',
         winner_count = (select count(*) from public.forum_lottery_winners where post_id = p_post_id)
   where post_id = p_post_id;
end;
$$;

-- ============================================================
-- 4. 取消参与：同样加锁，保持 entry_count 一致
-- ============================================================
create or replace function public.cancel_lottery_entry(p_post_id uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_status text;
begin
  if v_uid is null then
    raise exception '请先登录喵';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_post_id::text));

  select status into v_status from public.forum_lotteries where post_id = p_post_id;
  if v_status is null then
    raise exception '这不是一个抽奖帖喵';
  end if;
  if v_status <> 'drawing' then
    raise exception '该抽奖已开奖，无法取消参与喵';
  end if;
  if exists (select 1 from public.forum_lottery_entries
             where post_id = p_post_id and user_id = v_uid) then
    delete from public.forum_lottery_entries
     where post_id = p_post_id and user_id = v_uid;
    update public.forum_lotteries
       set entry_count = greatest(entry_count - 1, 0)
     where post_id = p_post_id;
  end if;
end;
$$;

-- ============================================================
-- 5. 剔除/禁止/解禁：同样加锁，保持 entry_count / banned_count 一致
-- ============================================================
create or replace function public.manage_lottery_entry(
  p_post_id uuid,
  p_target_user uuid,
  p_action text
)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_post_author uuid;
  v_lt_exists boolean;
  v_status text;
  v_was_entry boolean;
  v_was_ban boolean;
  v_entry_count integer;
  v_banned_count integer;
  v_action_taken text;
begin
  if v_uid is null then
    raise exception '请先登录喵';
  end if;
  if p_target_user is null then
    raise exception '请选择要操作的参与者喵';
  end if;
  if p_action not in ('remove','ban','unban') then
    raise exception '操作类型不合法喵';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_post_id::text));

  select exists(select 1 from public.forum_lotteries where post_id = p_post_id) into v_lt_exists;
  if not v_lt_exists then
    raise exception '这不是一个抽奖帖喵';
  end if;
  select role into v_role from public.profiles where id = v_uid;
  select author_id into v_post_author from public.forum_posts where id = p_post_id;
  if v_role not in ('owner','admin') and (v_post_author is null or v_post_author <> v_uid) then
    raise exception '只有发起人或站长/管理员能管理参与者喵';
  end if;
  select status into v_status from public.forum_lotteries where post_id = p_post_id;
  if v_status <> 'drawing' then
    raise exception '该抽奖已开奖，无法再管理参与者喵';
  end if;
  if p_target_user = v_uid then
    raise exception '不能对自己进行该操作喵';
  end if;

  select exists(select 1 from public.forum_lottery_entries where post_id = p_post_id and user_id = p_target_user)
    into v_was_entry;
  select exists(select 1 from public.forum_lottery_bans where post_id = p_post_id and user_id = p_target_user)
    into v_was_ban;

  if p_action = 'remove' then
    if v_was_entry then
      delete from public.forum_lottery_entries
       where post_id = p_post_id and user_id = p_target_user;
      delete from public.forum_lottery_winners
       where post_id = p_post_id and user_id = p_target_user;
      update public.forum_lotteries
         set entry_count = greatest(entry_count - 1, 0)
       where post_id = p_post_id;
    end if;
    v_action_taken := 'removed';
  elsif p_action = 'ban' then
    if v_was_entry then
      delete from public.forum_lottery_entries
       where post_id = p_post_id and user_id = p_target_user;
      delete from public.forum_lottery_winners
       where post_id = p_post_id and user_id = p_target_user;
      update public.forum_lotteries
         set entry_count = greatest(entry_count - 1, 0)
       where post_id = p_post_id;
    end if;
    if not v_was_ban then
      insert into public.forum_lottery_bans (post_id, user_id) values (p_post_id, p_target_user);
      update public.forum_lotteries
         set banned_count = banned_count + 1
       where post_id = p_post_id;
    end if;
    v_action_taken := 'banned';
  else
    if v_was_ban then
      delete from public.forum_lottery_bans
       where post_id = p_post_id and user_id = p_target_user;
      update public.forum_lotteries
         set banned_count = greatest(banned_count - 1, 0)
       where post_id = p_post_id;
    end if;
    v_action_taken := 'unbanned';
  end if;

  select entry_count into v_entry_count from public.forum_lotteries where post_id = p_post_id;
  select banned_count into v_banned_count from public.forum_lotteries where post_id = p_post_id;

  return jsonb_build_object(
    'action', v_action_taken,
    'removed_user_id', case when v_action_taken = 'removed' then p_target_user end,
    'banned_user_id', case when v_action_taken = 'banned' then p_target_user end,
    'unbanned_user_id', case when v_action_taken = 'unbanned' then p_target_user end,
    'entry_count', v_entry_count,
    'banned_count', v_banned_count
  );
end;
$$;
