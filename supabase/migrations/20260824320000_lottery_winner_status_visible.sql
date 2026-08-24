-- 91taffy.com 塔菲论坛抽奖：中奖状态与兑换码持续可见（2026-08-24）
-- 需求：雏草姬要上线了，要求中奖用户/未中奖用户进入自己参与的抽奖贴，
--       一直能看到自己的中奖状态；虚拟奖品中奖即视为已领取（兑换码直接展示），
--       实体奖品仍需填联系方式领取。
-- 改动：
--   1. draw_lottery_instant：虚拟奖品中奖时 claimed=true（兑换码直接展示），
--      实体奖品中奖 claimed=false（待填联系方式领取）
--   2. _lottery_draw_core（定时开奖核心）：同上，虚拟中奖 claimed=true，实体 claimed=false
--   3. claim_lottery_prize：实体必须填联系方式；虚拟无需填联系方式即可领取
--       （兼容旧数据里虚拟奖品 claimed=false 的残留记录）
-- 运行方式：psycopg2 直连生产库执行。幂等可重复执行。

-- ============================================================
-- 1. 即时开奖：虚拟中奖即已领取（claimed=true），实体中奖待填联系方式
--    基于最新版（含 deadline 校验 + 禁抽校验 + entry_count 同步）
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
-- 2. 定时开奖核心：虚拟中奖即已领取（claimed=true），实体中奖待填联系方式
--    基于最新版（含禁抽名单排除）
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
-- 3. 领取奖品：实体必须填联系方式；虚拟无需填联系方式即可领取
--    （兼容旧数据里虚拟奖品 claimed=false 的残留记录，让中奖者能直接领到码）
-- ============================================================
create or replace function public.claim_lottery_prize(
  p_post_id uuid,
  p_contact text default ''
)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_prize_type text;
  v_claimed boolean;
begin
  if v_uid is null then
    raise exception '请先登录喵';
  end if;
  select prize_type, claimed into v_prize_type, v_claimed
    from public.forum_lottery_winners
    where post_id = p_post_id and user_id = v_uid;
  if v_prize_type is null then
    raise exception '你没有中这个奖喵';
  end if;
  if v_claimed then
    raise exception '你已经领取过啦喵';
  end if;
  -- 实体奖品：必须填联系方式；虚拟奖品：直接领取（无需联系方式）
  if v_prize_type = 'physical' then
    if p_contact is null or trim(p_contact) = '' then
      raise exception '实体奖品需要填写联系方式（QQ/微信/电话等）才能领取喵';
    end if;
    update public.forum_lottery_winners
       set contact = trim(p_contact), claimed = true, claimed_at = now()
     where post_id = p_post_id and user_id = v_uid;
  else
    update public.forum_lottery_winners
       set claimed = true, claimed_at = now()
     where post_id = p_post_id and user_id = v_uid;
  end if;
end;
$$;
