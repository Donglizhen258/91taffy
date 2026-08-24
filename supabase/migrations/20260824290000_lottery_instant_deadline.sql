-- 91taffy.com 塔菲论坛抽奖：即时开奖模式支持限定时间（2026-08-24）
-- 需求：有些奖品有时效性，即时开奖也要能设置截止时间——到期后不能再抽，
--      未抽完的名额轮空（抽奖标记 drawn，已中奖者不受影响）。
-- 改动：
--   1. draw_lottery_instant：抽奖前校验 deadline，已到期拒绝
--   2. maybe_auto_draw：支持即时模式到期自动收尾（未抽完名额轮空，标记 drawn）
-- 运行方式：Supabase 控制台 SQL Editor 或 psycopg2 直连执行。幂等可重复执行。

-- ============================================================
-- 1. 即时开奖 RPC：增加截止时间校验
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
  -- 截止时间校验（新增）：已到期不能再抽
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
      insert into public.forum_lottery_winners (post_id, user_id, prize_name, prize_type, code)
      values (p_post_id, v_uid, v_prize_name, v_prize_type, v_code);
    end if;
  end if;

  -- 参与数是否已抽满 -> 结束
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
-- 2. maybe_auto_draw：支持即时模式到期自动收尾
--    （draw_mode 不限 scheduled；即时模式到期：未抽完的名额轮空，标记 drawn）
-- ============================================================
create or replace function public.maybe_auto_draw(p_post_id uuid)
returns boolean
language plpgsql security definer
set search_path = public
as $$
declare
  v_lottery record;
begin
  select * into v_lottery from public.forum_lotteries where post_id = p_post_id;
  if v_lottery.post_id is null then
    return false;
  end if;
  -- 进行中、有截止时间、且截止时间已过才自动收尾（定时模式开奖 / 即时模式轮空）
  if v_lottery.status <> 'drawing'
     or v_lottery.deadline is null
     or v_lottery.deadline >= now() then
    return false;
  end if;
  if v_lottery.draw_mode = 'scheduled' then
    perform public._lottery_draw_core(p_post_id);
  else
    -- 即时模式：到期直接收尾，未抽完的名额轮空（已中奖者保留）
    update public.forum_lotteries
       set status = 'drawn',
           winner_count = (select count(*) from public.forum_lottery_winners where post_id = p_post_id)
     where post_id = p_post_id;
  end if;
  return true;
end;
$$;

-- ============================================================
-- 3. 手动结束即时抽奖 RPC（仅 楼主/站长/管理员）
--    立即收尾：未抽完的名额轮空（已中奖者保留），status -> drawn
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
  -- 收尾：未抽完的名额轮空，已中奖者保留
  update public.forum_lotteries
     set status = 'drawn',
         winner_count = (select count(*) from public.forum_lottery_winners where post_id = p_post_id)
   where post_id = p_post_id;
end;
$$;
