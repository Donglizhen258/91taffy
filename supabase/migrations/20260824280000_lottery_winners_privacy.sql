-- 91taffy.com 塔菲论坛抽奖：修复兑换码/联系方式隐私泄露（2026-08-24）
-- 问题：forum_lottery_winners 的 SELECT 策略是 public read (true)，
--       任何匿名用户都能通过 REST 直接读到所有中奖者的兑换码(code)和联系方式(contact)，
--       可把即时抽奖所有虚拟奖品兑换码偷走，导致明早大抽奖被薅空。
-- 修复：
--   1. 收紧 winners RLS：仅 本人 / 楼主 / 站长 / 管理员 可读
--   2. 新增 RPC get_lottery_winners：
--      - 普通用户/匿名：返回脱敏中奖名单（昵称/奖品/领取状态，不含 code/contact）
--      - 楼主/站长/管理员：返回完整名单（含 code/contact）
--   3. 中奖者本人仍可直接查自己的记录（领奖看兑换码）
-- 运行方式：Supabase 控制台 SQL Editor 或 psycopg2 直连执行。幂等可重复执行。

-- ============================================================
-- 1. 收紧 winners RLS：本人 + 楼主/站长/管理员
-- ============================================================
drop policy if exists "public read forum_lottery_winners" on public.forum_lottery_winners;
create policy "public read forum_lottery_winners" on public.forum_lottery_winners
  for select using (
    auth.uid() = user_id
    or exists (
      select 1 from public.forum_posts fp
      where fp.id = post_id and fp.author_id = auth.uid()
    )
    or exists (
      select 1 from public.profiles pr
      where pr.id = auth.uid() and pr.role in ('owner','admin')
    )
  );

-- ============================================================
-- 2. 中奖名单 RPC（脱敏公开 / 完整管理层）
--    返回 jsonb 数组（按领取状态+开奖时间排序）：
--    [{user_id, nickname, username, uid, avatar_url, prize_name, prize_type,
--      claimed, claimed_at, code(仅管理层), contact(仅管理层)}]
-- ============================================================
create or replace function public.get_lottery_winners(p_post_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_post_author uuid;
  v_is_manager boolean := false;
  v_lt_exists boolean;
  v_result jsonb;
begin
  select exists(select 1 from public.forum_lotteries where post_id = p_post_id) into v_lt_exists;
  if not v_lt_exists then
    raise exception '这不是一个抽奖帖喵';
  end if;
  if v_uid is not null then
    select role into v_role from public.profiles where id = v_uid;
    select author_id into v_post_author from public.forum_posts where id = p_post_id;
    -- 仅站长(owner) 或 发帖人(楼主) 可看完整名单(含 code/contact)，管理员 admin 也不得看（防徇私舞弊）
    v_is_manager := (v_role = 'owner') or (v_post_author is not null and v_post_author = v_uid);
  end if;

  if v_is_manager then
    -- 管理层：完整数据（含 code/contact）
    select coalesce(jsonb_agg(
             jsonb_build_object(
               'user_id', w.user_id,
               'nickname', p.nickname,
               'username', p.username,
               'uid', p.uid,
               'avatar_url', p.avatar_url,
               'prize_name', w.prize_name,
               'prize_type', w.prize_type,
               'claimed', w.claimed,
               'claimed_at', w.claimed_at,
               'code', w.code,
               'contact', w.contact
             ) order by w.claimed asc, w.claimed_at nulls last, w.user_id
           ), '[]'::jsonb)
      into v_result
      from public.forum_lottery_winners w
      left join public.profiles p on p.id = w.user_id
     where w.post_id = p_post_id;
  else
    -- 公开：脱敏（不含 code/contact）
    select coalesce(jsonb_agg(
             jsonb_build_object(
               'user_id', w.user_id,
               'nickname', p.nickname,
               'username', p.username,
               'uid', p.uid,
               'avatar_url', p.avatar_url,
               'prize_name', w.prize_name,
               'prize_type', w.prize_type,
               'claimed', w.claimed,
               'claimed_at', w.claimed_at
             ) order by w.claimed asc, w.claimed_at nulls last, w.user_id
           ), '[]'::jsonb)
      into v_result
      from public.forum_lottery_winners w
      left join public.profiles p on p.id = w.user_id
     where w.post_id = p_post_id;
  end if;

  return v_result;
end;
$$;

-- ============================================================
-- 3. maybe_auto_draw 放开匿名触发（解决：未登录用户访问已截止的定时抽奖不自动开奖）
--    函数内部严格校验（仅 scheduled + drawing + 截止已过 + 幂等），匿名触发安全
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
  if v_lottery.draw_mode <> 'scheduled'
     or v_lottery.status <> 'drawing'
     or v_lottery.deadline is null
     or v_lottery.deadline >= now() then
    return false;
  end if;
  perform public._lottery_draw_core(p_post_id);
  return true;
end;
$$;
