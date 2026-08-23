-- 91taffy.com 塔菲论坛抽奖功能（2026-08-23）
-- 运行方式：Supabase 控制台 -> SQL Editor -> 粘贴执行（或 psycopg2 直连执行）
-- 功能：抽奖贴作为普通帖子发放。抽奖只能由站长/管理员发起。
--      支持多奖项（虚拟/实体），虚拟奖品中奖后直接领取，实体奖品中奖人填联系方式领取。
-- 表：
--   forum_lotteries        抽奖配置（prizes 用 JSONB 存奖项数组）
--   forum_lottery_entries  参与记录（复合主键防重复参与）
--   forum_lottery_winners  中奖记录（含领取状态 + 实体奖品联系方式）
-- 全部语句幂等，可重复执行

-- ============================================================
-- 1. 抽奖配置表（一帖一抽奖）
--    prizes: [{ "name":"奖品名","type":"virtual|physical","count":数量 }]
--    status: drawing=进行中 / drawn=已开奖 / cancelled=已取消
--    deadline: 参与截止时间（null=一直可参与直到开奖）
-- ============================================================
create table if not exists public.forum_lotteries (
  post_id uuid primary key references public.forum_posts(id) on delete cascade,
  prizes jsonb not null default '[]',
  deadline timestamptz,
  claim_note text default '',
  status text not null default 'drawing' check (status in ('drawing','drawn','cancelled')),
  winner_count integer not null default 0,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now() not null
);
comment on table public.forum_lotteries is '塔菲论坛抽奖：prizes JSONB 存奖项数组，winner_count 中奖总人数';

-- ============================================================
-- 2. 参与记录表（复合主键防重复参与）
-- ============================================================
create table if not exists public.forum_lottery_entries (
  post_id uuid references public.forum_posts(id) on delete cascade not null,
  user_id uuid references public.profiles(id) on delete cascade not null,
  created_at timestamptz default now() not null,
  primary key (post_id, user_id)
);
comment on table public.forum_lottery_entries is '塔菲论坛抽奖参与记录';

create index if not exists idx_lottery_entries_post
  on public.forum_lottery_entries (post_id);

-- ============================================================
-- 3. 中奖记录表（含领取状态 + 实体奖品联系方式）
--    claimed: 是否已领取；实体奖品需先填 contact 再领取
-- ============================================================
create table if not exists public.forum_lottery_winners (
  post_id uuid references public.forum_posts(id) on delete cascade not null,
  user_id uuid references public.profiles(id) on delete cascade not null,
  prize_name text not null,
  prize_type text not null check (prize_type in ('virtual','physical')),
  contact text default '',
  claimed boolean not null default false,
  claimed_at timestamptz,
  primary key (post_id, user_id)
);
comment on table public.forum_lottery_winners is '塔菲论坛抽奖中奖记录（含领取状态与联系方式）';

create index if not exists idx_lottery_winners_post
  on public.forum_lottery_winners (post_id);

-- ============================================================
-- 4. RLS 权限
-- ============================================================
alter table public.forum_lotteries enable row level security;
alter table public.forum_lottery_entries enable row level security;
alter table public.forum_lottery_winners enable row level security;

-- 抽奖配置：所有人可读
drop policy if exists "public read forum_lotteries" on public.forum_lotteries;
create policy "public read forum_lotteries" on public.forum_lotteries
  for select using (true);

-- 参与记录：所有人可读（人数聚合 + 中奖名单去重需要）；本人可写
drop policy if exists "public read forum_lottery_entries" on public.forum_lottery_entries;
create policy "public read forum_lottery_entries" on public.forum_lottery_entries
  for select using (true);
drop policy if exists "auth insert forum_lottery_entries" on public.forum_lottery_entries;
create policy "auth insert forum_lottery_entries" on public.forum_lottery_entries
  for insert with check (auth.uid() = user_id);
drop policy if exists "auth delete forum_lottery_entries" on public.forum_lottery_entries;
create policy "auth delete forum_lottery_entries" on public.forum_lottery_entries
  for delete using (auth.uid() = user_id);

-- 中奖记录：所有人可读（中奖名单公开）
drop policy if exists "public read forum_lottery_winners" on public.forum_lottery_winners;
create policy "public read forum_lottery_winners" on public.forum_lottery_winners
  for select using (true);

-- ============================================================
-- 5. 发起抽奖 RPC（发帖 + 建抽奖一体，仅站长/管理员）
--    p_prizes: JSONB 数组 [{name,type,count},...]
--    p_deadline: 参与截止时间（可 null）
--    p_as_assistant: 可选以「站内管家」(UID 1) 署名
-- ============================================================
create or replace function public.create_lottery_post(
  p_title text,
  p_content text,
  p_prizes jsonb,
  p_image_url text default '',
  p_deadline timestamptz default null,
  p_claim_note text default '',
  p_as_assistant boolean default false
)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_me uuid;
  v_role text;
  v_post_id uuid;
  v_prize_count integer;
begin
  if v_uid is null then
    raise exception '请先登录喵';
  end if;
  select id, role into v_me, v_role from public.profiles where id = v_uid;
  if v_me is null or v_role not in ('owner','admin') then
    raise exception '只有站长/管理员能发起抽奖喵';
  end if;
  if p_prizes is null or jsonb_array_length(p_prizes) = 0 then
    raise exception '至少要有一个奖品喵';
  end if;
  -- 校验奖品格式
  select count(*) into v_prize_count from jsonb_array_elements(p_prizes) as p
    where p->>'name' is null or p->>'name' = ''
       or p->>'type' not in ('virtual','physical')
       or coalesce((p->>'count')::int, 0) < 1;
  if v_prize_count > 0 then
    raise exception '奖品配置有误：需包含名称、类型(virtual/physical)、数量喵';
  end if;

  -- 可选以助手身份署名
  if p_as_assistant then
    v_me := (select id from public.profiles where uid = 1);
    if v_me is null then raise exception '网站助手账号不存在喵'; end if;
  end if;

  -- 创建普通帖子（抽奖贴 = 普通帖，可被置顶/加精）
  insert into public.forum_posts (title, content, image_url, author_id, post_type, is_pinned)
  values (p_title, p_content, coalesce(p_image_url,''), v_me, 'post', false)
  returning id into v_post_id;

  -- 建抽奖配置
  insert into public.forum_lotteries (post_id, prizes, deadline, claim_note, created_by)
  values (v_post_id, p_prizes, p_deadline, coalesce(p_claim_note,''), v_me);

  return v_post_id;
end;
$$;

-- ============================================================
-- 6. 参与抽奖 RPC（登录用户，开奖前可参与，防重复）
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
  v_lottery_exists boolean;
begin
  if v_uid is null then
    raise exception '请先登录喵';
  end if;
  if not exists (select 1 from public.profiles p where p.id = v_uid and p.status = 'active') then
    raise exception '账号异常或被封禁，无法参与抽奖喵';
  end if;
  select exists(select 1 from public.forum_lotteries where post_id = p_post_id)
    into v_lottery_exists;
  if not v_lottery_exists then
    raise exception '这不是一个抽奖帖喵';
  end if;
  select status, deadline into v_status, v_deadline
    from public.forum_lotteries where post_id = p_post_id;
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
end;
$$;

-- ============================================================
-- 7. 取消参与 RPC（开奖前可取消）
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
  select status into v_status from public.forum_lotteries where post_id = p_post_id;
  if v_status is null then
    raise exception '这不是一个抽奖帖喵';
  end if;
  if v_status <> 'drawing' then
    raise exception '该抽奖已开奖，无法取消参与喵';
  end if;
  delete from public.forum_lottery_entries
   where post_id = p_post_id and user_id = v_uid;
end;
$$;

-- ============================================================
-- 8. 开奖 RPC（仅发起人 / 站长 / 管理员）
--    逐奖项随机抽取，中奖者不重复；参与不足时全中，剩余名额轮空
-- ============================================================
create or replace function public.draw_lottery(p_post_id uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_lottery record;
  v_post_author uuid;
  v_entrants uuid[];
  v_already_won uuid[] := '{}';
  v_prize record;
  v_i integer;
  v_idx integer;
  v_pick uuid;
  v_total_winners integer := 0;
begin
  if v_uid is null then
    raise exception '请先登录喵';
  end if;
  select role into v_role from public.profiles where id = v_uid;
  select * into v_lottery from public.forum_lotteries where post_id = p_post_id;
  if v_lottery.post_id is null then
    raise exception '这不是一个抽奖帖喵';
  end if;
  -- 开奖权限：站长/管理员，或帖子楼主本人（助手署名时帖主是 uid1，owner 仍可开）
  select author_id into v_post_author from public.forum_posts where id = p_post_id;
  if v_role not in ('owner','admin') and (v_post_author is null or v_post_author <> v_uid) then
    raise exception '只有发起人或站长/管理员能开奖喵';
  end if;
  if v_lottery.status <> 'drawing' then
    raise exception '该抽奖已开奖或已结束喵';
  end if;

  -- 收集参与者
  select array_agg(user_id order by random())
    into v_entrants
    from public.forum_lottery_entries
    where post_id = p_post_id;
  if v_entrants is null or cardinality(v_entrants) = 0 then
    -- 无人参与：直接标记已开奖（无人中奖）
    update public.forum_lotteries
       set status = 'drawn', winner_count = 0
     where post_id = p_post_id;
    return;
  end if;

  -- 逐奖项抽取
  for v_prize in select * from jsonb_array_elements(v_lottery.prizes) as p
    where (p->>'count')::int >= 1
  loop
    v_i := 0;
    while v_i < (v_prize.value->>'count')::int loop
      exit when cardinality(v_entrants) = 0;
      -- 从未中奖者里随机取一个
      v_idx := 1 + floor(random() * cardinality(v_entrants))::int;
      v_pick := v_entrants[v_idx];
      -- 从参与者数组移除（保证不重复中奖）
      v_entrants := v_entrants[1:v_idx-1] || v_entrants[v_idx+1:cardinality(v_entrants)];
      insert into public.forum_lottery_winners (post_id, user_id, prize_name, prize_type)
      values (p_post_id, v_pick, v_prize.value->>'name', v_prize.value->>'type');
      v_total_winners := v_total_winners + 1;
      v_i := v_i + 1;
    end loop;
  end loop;

  update public.forum_lotteries
     set status = 'drawn', winner_count = v_total_winners
   where post_id = p_post_id;
end;
$$;

-- ============================================================
-- 9. 领取奖品 RPC
--    虚拟奖品：直接领取（contact 可空）
--    实体奖品：必须填写联系方式（QQ/微信/电话等）才能领取
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
