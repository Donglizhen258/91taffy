-- 91taffy.com 塔菲论坛抽奖：参与者名单 + 剔除/禁止参与者（2026-08-24）
-- 需求：
--   1. 普通用户可见抽奖当前已参与人数（已有，本次在列表页也显示）
--   2. 管理员/站长 + 发起人（楼主）可见参与者详细名单
--   3. 发起者/站长/管理员可剔除参与者（恢复为未参与状态）或禁止其参与本次抽奖（可选）
-- 改动：
--   1. 新增 forum_lottery_bans 表：禁抽名单（post_id+user_id）
--   2. forum_lotteries 新增 banned_count 列（方便前端直接展示禁抽人数）
--   3. 新增 RPC list_lottery_participants：仅楼主/站长/管理员可查参与者名单
--   4. 新增 RPC manage_lottery_entry：剔除(remove)/禁止(ban)/恢复(unban) 参与者，开奖后不可操作
--   5. enter_lottery / draw_lottery_instant：校验禁抽名单 + 同步 entry_count
--   6. cancel_lottery_entry / manage_lottery_entry 剔除：同步扣减 entry_count
--   7. 收紧 RLS：entries 的 select 仅本人/楼主/站长/管理员可见（防止普通用户直接读出名单）
-- 运行方式：Supabase 控制台 SQL Editor 或 psycopg2 直连执行。幂等可重复执行。

-- ============================================================
-- 1. 禁抽名单表 + 禁抽人数列
-- ============================================================
create table if not exists public.forum_lottery_bans (
  post_id uuid references public.forum_posts(id) on delete cascade not null,
  user_id uuid references public.profiles(id) on delete cascade not null,
  created_at timestamptz default now() not null,
  primary key (post_id, user_id)
);
comment on table public.forum_lottery_bans is '塔菲论坛抽奖禁抽名单';

create index if not exists idx_lottery_bans_post
  on public.forum_lottery_bans (post_id);

alter table public.forum_lotteries
  add column if not exists banned_count integer not null default 0;
comment on column public.forum_lotteries.banned_count is '被禁止参与本次抽奖的人数';

-- 权限：禁抽名单仅楼主/站长/管理员可见（普通用户看不到"谁被禁"）
alter table public.forum_lottery_bans enable row level security;

drop policy if exists "owner read forum_lottery_bans" on public.forum_lottery_bans;
create policy "owner read forum_lottery_bans" on public.forum_lottery_bans
  for select using (
    exists (
      select 1 from public.forum_posts fp
      where fp.id = post_id and fp.author_id = auth.uid()
    )
    or exists (
      select 1 from public.profiles pr
      where pr.id = auth.uid() and pr.role in ('owner','admin')
    )
  );

drop policy if exists "owner write forum_lottery_bans" on public.forum_lottery_bans;
create policy "owner write forum_lottery_bans" on public.forum_lottery_bans
  for all using (
    exists (
      select 1 from public.forum_posts fp
      where fp.id = post_id and fp.author_id = auth.uid()
    )
    or exists (
      select 1 from public.profiles pr
      where pr.id = auth.uid() and pr.role in ('owner','admin')
    )
  );

-- ============================================================
-- 2. 收紧 entries RLS：select 仅本人/楼主/站长/管理员（名单不向普通用户公开）
-- ============================================================
drop policy if exists "public read forum_lottery_entries" on public.forum_lottery_entries;
create policy "public read forum_lottery_entries" on public.forum_lottery_entries
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
-- 3. 参与抽奖 RPC：检查禁抽名单 + 同步 entry_count
--    （定时模式用；即时模式用 draw_lottery_instant，同样校验）
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
  -- 禁抽名单校验
  if exists (select 1 from public.forum_lottery_bans where post_id = p_post_id and user_id = v_uid) then
    raise exception '你已被禁止参与本次抽奖喵';
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
-- 4. 取消参与 RPC：同步扣减 entry_count
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
-- 5. 参与者名单 RPC（仅楼主/站长/管理员）
--    返回 jsonb：{ list:[{user_id,nickname,username,uid,avatar_url,created_at}], total, max_entries }
-- ============================================================
create or replace function public.list_lottery_participants(p_post_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_post_author uuid;
  v_lt_exists boolean;
  v_result jsonb;
  v_total integer;
  v_max integer;
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
  -- 仅站长(owner) 或 发帖人(楼主) 可查看，管理员 admin 也不得查看（防徇私舞弊）
  if v_role <> 'owner' and (v_post_author is null or v_post_author <> v_uid) then
    raise exception '只有发起人或站长能查看参与者名单喵';
  end if;
  select count(*) into v_total
    from public.forum_lottery_entries where post_id = p_post_id;
  select max_entries into v_max
    from public.forum_lotteries where post_id = p_post_id;
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'user_id', e.user_id,
             'nickname', p.nickname,
             'username', p.username,
             'uid', p.uid,
             'avatar_url', p.avatar_url,
             'created_at', e.created_at
           ) order by e.created_at
         ), '[]'::jsonb)
    into v_result
    from public.forum_lottery_entries e
    left join public.profiles p on p.id = e.user_id
   where e.post_id = p_post_id;
  return jsonb_build_object('list', v_result, 'total', v_total, 'max_entries', v_max);
end;
$$;

-- ============================================================
-- 6. 剔除/禁止/恢复 RPC（仅楼主/站长/管理员；开奖后不可操作）
--    p_action: remove=剔除(恢复未参与，可再参与) / ban=禁止参与 / unban=恢复(解除禁止)
--    返回 jsonb：{ entry_count, banned_count, removed_user_id, banned_user_id, unbanned_user_id }
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
  select exists(select 1 from public.forum_lotteries where post_id = p_post_id) into v_lt_exists;
  if not v_lt_exists then
    raise exception '这不是一个抽奖帖喵';
  end if;
  select role into v_role from public.profiles where id = v_uid;
  select author_id into v_post_author from public.forum_posts where id = p_post_id;
  -- 仅站长(owner) 或 发帖人(楼主) 可管理，管理员 admin 也不得操作（防徇私舞弊）
  if v_role <> 'owner' and (v_post_author is null or v_post_author <> v_uid) then
    raise exception '只有发起人或站长能管理参与者喵';
  end if;
  select status into v_status from public.forum_lotteries where post_id = p_post_id;
  if v_status <> 'drawing' then
    raise exception '该抽奖已开奖，无法再管理参与者喵';
  end if;
  -- 禁止自己（发起人/管理员）没有意义，直接拒绝
  if p_target_user = v_uid then
    raise exception '不能对自己进行该操作喵';
  end if;

  select exists(select 1 from public.forum_lottery_entries where post_id = p_post_id and user_id = p_target_user)
    into v_was_entry;
  select exists(select 1 from public.forum_lottery_bans where post_id = p_post_id and user_id = p_target_user)
    into v_was_ban;

  if p_action = 'remove' then
    -- 剔除：删除参与记录（含可能的中奖记录），恢复为未参与状态（可再参与）
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
    -- 禁止：同时从参与名单剔除（含中奖记录）+ 加入禁抽名单
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
    -- unban：解除禁止
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

-- ============================================================
-- 7. 即时开奖 RPC：校验禁抽名单 + 同步 entry_count（保持与定时一致）
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
-- 8. 开奖核心：剔除的参与者不再参与开奖（剔除已删除 entries，无需额外处理）
--    _lottery_draw_core 以 entries 表为准，已剔除者自然不参与。
--    但需注意：禁止者可能仍在 entries 中？不会——ban 会同时删除 entry。
--    为保险起见，开奖时也排除禁抽名单中残留的 entries。
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
      insert into public.forum_lottery_winners (post_id, user_id, prize_name, prize_type, code)
      values (p_post_id, v_pick, v_prize.v->>'name', v_prize.v->>'type', v_code);
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
-- 9. 历史数据校正：定时模式旧数据 entry_count 之前未维护，统一补齐
-- ============================================================
update public.forum_lotteries lt
   set entry_count = (
     select count(*) from public.forum_lottery_entries e where e.post_id = lt.post_id
   )
 where lt.status = 'drawing' and lt.draw_mode = 'scheduled'
   and lt.entry_count = 0
   and exists (select 1 from public.forum_lottery_entries e where e.post_id = lt.post_id);
