-- 91taffy.com 塔菲论坛抽奖：领奖需先填具体信息/联系方式（2026-08-23）
-- 需求：实体奖品和虚拟奖品，领奖人都要先填写自己的具体信息/联系方式才能领取。
--      兑换码只在填完信息领取后才展示给中奖者。
-- 改动：
--   1. claim_lottery_prize：不再区分虚拟/实体，统一要求 p_contact 非空才允许领取
--   2. draw_lottery_instant：即时开奖的虚拟奖品中奖后不再自动 claimed（待填联系方式后领），
--      兑换码在中奖记录里（code 列），填完信息领奖后前端展示
-- 运行方式：Supabase 控制台 SQL Editor 或 psycopg2 直连执行。幂等可重复执行。

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
  -- 统一要求：实体和虚拟奖品都必须先填具体信息/联系方式
  if p_contact is null or trim(p_contact) = '' then
    raise exception '请先填写你的具体信息/联系方式（QQ/微信/电话等）才能领取喵';
  end if;
  update public.forum_lottery_winners
     set contact = trim(p_contact), claimed = true, claimed_at = now()
   where post_id = p_post_id and user_id = v_uid;
end;
$$;

-- 即时开奖：虚拟奖品中奖后不自动领取（待填联系方式后领，兑换码存 code 列待领取后展示）
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
  v_alloc_idx integer;
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
  if exists (select 1 from public.forum_lottery_entries where post_id = p_post_id and user_id = v_uid)
     or exists (select 1 from public.forum_lottery_winners where post_id = p_post_id and user_id = v_uid) then
    raise exception '你已经参与过这个抽奖啦喵';
  end if;
  if v_lottery.entry_count >= v_lottery.max_entries then
    raise exception '该抽奖名额已抽完喵';
  end if;

  -- 占用一个参与名额（先写 entries，保持数据一致）
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

  -- 本次抽奖后剩余可抽次数
  v_chances_left := v_lottery.max_entries - v_entered_after;

  -- 中奖判定：保证名额最终抽完（剩余名额>=剩余次数则必中）
  if v_remaining_prizes > 0 then
    if v_chances_left <= 0 or v_remaining_prizes >= v_chances_left then
      v_won := true;
    else
      v_won := (random() < v_remaining_prizes::float / v_chances_left::float);
    end if;
  end if;

  -- 抽中：从还有名额的奖品中随机选一个，分配兑换码（虚拟奖品预存 code，待领后展示）
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
      -- 无论虚拟/实体，中奖后都是「待领取」状态（需先填联系方式），兑换码存 code 列待领后展示
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
