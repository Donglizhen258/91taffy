-- 91taffy.com 塔菲论坛：回帖删除 RPC + 抽奖即时模式已参与判定修复（2026-08-23）
-- 背景：
--   1. forum_replies 无 delete RLS 策略，前端直连 delete 会失败。新增 security definer RPC：
--      - 回帖作者本人可删自己的回帖（含楼中楼）
--      - 帖子楼主可删自己楼内的任意回帖
--      - 站长/管理员可删任意回帖
--      - 删主回帖时级联删除其下所有楼中楼
--   2. draw_lottery_instant 此前「已参与」只查 entries 表，未把参与者写入 entries，
--      导致重复抽奖时报 winners 主键冲突而非友好提示。修复为查 entries+winners 双表，
--      并让每次即时抽奖都写入 entries 记录。
-- 运行方式：Supabase 控制台 SQL Editor 或 psycopg2 直连执行。幂等可重复执行。

-- ============================================================
-- 1. 回帖删除 RPC
-- ============================================================
create or replace function public.delete_forum_reply(p_reply_id uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_reply_author uuid;
  v_post_id uuid;
  v_post_author uuid;
begin
  if v_uid is null then
    raise exception '请先登录喵';
  end if;
  select role into v_role from public.profiles where id = v_uid;
  select author_id, post_id into v_reply_author, v_post_id
    from public.forum_replies where id = p_reply_id;
  if v_post_id is null then
    raise exception '这条回帖不存在或已删除喵';
  end if;
  select author_id into v_post_author from public.forum_posts where id = v_post_id;

  -- 权限：站长/管理员 / 回帖作者本人 / 帖子楼主
  if v_role not in ('owner','admin')
     and (v_reply_author is null or v_reply_author <> v_uid)
     and (v_post_author is null or v_post_author <> v_uid) then
    raise exception '你没有权限删除这条回帖喵';
  end if;

  -- 删除（主回帖会通过外键 on delete cascade 级联删掉楼中楼）
  delete from public.forum_replies where id = p_reply_id;

  -- 更新帖子统计
  update public.forum_posts
     set reply_count = (select count(*) from public.forum_replies where post_id = v_post_id)
   where id = v_post_id;
end;
$$;

-- ============================================================
-- 2. 修复 draw_lottery_instant 已参与判定 + 写入参与记录
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

  -- 抽中：从还有名额的奖品中随机选一个，分配兑换码
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
      -- 即时开奖：虚拟奖品中奖即视为已领取（兑换码直接展示），实体奖品仍需填联系方式
      if v_prize_type = 'virtual' then
        insert into public.forum_lottery_winners (post_id, user_id, prize_name, prize_type, code, claimed, claimed_at)
        values (p_post_id, v_uid, v_prize_name, v_prize_type, v_code, true, now());
      else
        insert into public.forum_lottery_winners (post_id, user_id, prize_name, prize_type, code)
        values (p_post_id, v_uid, v_prize_name, v_prize_type, v_code);
      end if;
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
