-- 91taffy.com uid 冻结/回调 + 评论 uid 快照（2026-08-23 v2）
-- 运行方式：Supabase 控制台 -> SQL Editor -> 粘贴执行（或随 Git 集成自动迁移）
-- 全部语句幂等，可重复执行
-- 需求与设计：
--   1. 用户被删除后，其 uid 进入冻结池 deleted_uids（recycled=false，冻结中，不会自动发给新用户）
--   2. 站长在管理面板看到已删除 uid 列表（含冻结/已回调状态）
--   3. 站长点「回调」→ 该 uid 标记 recycled=true，放回注册池
--   4. 新用户注册时优先取「已回调」的最小 uid；取走后删除冻结记录，并清除该 uid 的历史评论痕迹（author_uid 快照置空）
--   5. comments 冗余 author_uid 快照：用户被删后评论仍显示其原 uid；一旦 uid 被新主人占用，旧快照即清除
-- 注意：冻结中的 uid 不会自动复用，必须站长手动回调后才进入注册池

-- ============ 0. profiles 加 uid 快照列（备用） ============
alter table public.profiles add column if not exists uid_snapshot integer;

-- ============ 1. comments 加 author_uid 快照列 ============
alter table public.comments add column if not exists author_uid integer;

-- 历史数据回填：已存在评论的 author_uid 用当时作者 uid 填上
update public.comments c
set author_uid = p.uid
from public.profiles p
where c.author_id = p.id
  and c.author_uid is null;

-- ============ 2. uid 冻结池表（recycled=false 冻结 / true 已回调可复用） ============
create table if not exists public.deleted_uids (
  uid integer primary key,
  deleted_at timestamptz default now() not null,
  note text default '',
  recycled boolean not null default false
);
alter table public.deleted_uids enable row level security;
create policy "admin read deleted_uids" on public.deleted_uids
  for select using (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('owner','admin'))
  );
create policy "admin write deleted_uids" on public.deleted_uids
  for all using (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('owner','admin'))
  );

-- ============ 3. 删除用户 RPC：uid 进冻结池（不自动复用） ============
create or replace function public.admin_delete_user(target_id uuid)
returns void
language plpgsql security definer
as $$
declare
  v_me_role text;
  v_uid integer;
  v_name text;
begin
  select role into v_me_role from public.profiles where id = auth.uid();
  if v_me_role is null or v_me_role not in ('owner','admin') then
    raise exception '仅站长/管理员可删除用户';
  end if;
  if target_id = auth.uid() then
    raise exception '不能删除自己的账号';
  end if;
  select uid, coalesce(nickname, username, '') into v_uid, v_name
  from public.profiles where id = target_id;
  if v_uid is null then
    raise exception '目标用户不存在';
  end if;
  if exists (select 1 from public.profiles where id = target_id and role = 'owner') then
    raise exception '不能删除站长账号';
  end if;
  -- uid 进冻结池（幂等）
  insert into public.deleted_uids (uid, note)
  values (v_uid, coalesce(v_name, ''))
  on conflict (uid) do nothing;
  -- 删除 auth.users（级联清 profiles / comment_likes / comment_log）
  delete from auth.users where id = target_id;
end;
$$;
grant execute on function public.admin_delete_user(uuid) to authenticated;

-- ============ 4. 回调 RPC：站长手动把冻结 uid 放回注册池 ============
create or replace function public.admin_recycle_uid(target_uid integer)
returns void
language plpgsql security definer
as $$
declare
  v_me_role text;
begin
  select role into v_me_role from public.profiles where id = auth.uid();
  if v_me_role is null or v_me_role not in ('owner','admin') then
    raise exception '仅站长/管理员可回调 uid';
  end if;
  update public.deleted_uids set recycled = true where uid = target_uid;
end;
$$;
grant execute on function public.admin_recycle_uid(integer) to authenticated;

-- ============ 5. 建号函数升级：优先取「已回调」的最小 uid ============
create or replace function public.handle_new_user()
returns trigger as $$
declare
  v_email text;
  v_uid integer;
  v_role text;
begin
  if new.email_confirmed_at is null then
    return new;
  end if;
  if exists (select 1 from public.profiles where id = new.id) then
    return new;
  end if;
  v_email := lower(coalesce(new.email, ''));
  if not exists (select 1 from public.profiles) then
    v_uid := 0;
    v_role := 'owner';
  else
    -- 优先取「已回调」的最小 uid（冻结中的不取）
    select min(uid) into v_uid from public.deleted_uids where recycled = true;
    if v_uid is null then
      v_uid := nextval('public.uid_seq');
    else
      -- 已被新用户占用：移除冻结记录 + 清除该 uid 的历史评论痕迹
      delete from public.deleted_uids where uid = v_uid;
      update public.comments set author_uid = null where author_uid = v_uid;
    end if;
    v_role := 'user';
  end if;
  insert into public.profiles (id, uid, email, username, nickname, gender, role, status)
  values (
    new.id,
    v_uid,
    nullif(v_email, ''),
    coalesce(new.raw_user_meta_data->>'username', 'user_' || substr(new.id::text, 1, 8)),
    coalesce(new.raw_user_meta_data->>'nickname', new.raw_user_meta_data->>'username'),
    coalesce(new.raw_user_meta_data->>'gender', '保密'),
    v_role,
    'active'
  );
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

drop trigger if exists on_auth_user_confirmed on auth.users;
create trigger on_auth_user_confirmed
  after update of email_confirmed_at on auth.users
  for each row execute procedure public.handle_new_user();

-- ============ 6. ensure_profile 兜底同样优先回调 ============
create or replace function public.ensure_profile(
  p_id uuid,
  p_email text,
  p_username text default null,
  p_nickname text default null
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_email text;
  v_uid integer;
  v_role text;
begin
  if p_id <> auth.uid() then
    return;
  end if;
  if exists (select 1 from public.profiles where id = p_id) then
    return;
  end if;
  v_email := lower(coalesce(p_email, ''));
  if not exists (select 1 from public.profiles) then
    v_uid := 0;
    v_role := 'owner';
  else
    select min(uid) into v_uid from public.deleted_uids where recycled = true;
    if v_uid is null then
      v_uid := nextval('public.uid_seq');
    else
      delete from public.deleted_uids where uid = v_uid;
      update public.comments set author_uid = null where author_uid = v_uid;
    end if;
    v_role := 'user';
  end if;
  insert into public.profiles (id, uid, email, username, nickname, gender, role, status)
  values (
    p_id,
    v_uid,
    nullif(v_email, ''),
    coalesce(p_username, 'user_' || substr(p_id::text, 1, 8)),
    coalesce(p_nickname, p_username),
    '保密',
    v_role,
    'active'
  );
end;
$$;
grant execute on function public.ensure_profile(uuid, text, text, text) to anon, authenticated;

-- ============ 7. 评论快照触发器：发评论时自动记 author_uid ============
create or replace function public.comment_snapshot_uid()
returns trigger as $$
declare
  v_uid integer;
begin
  select uid into v_uid from public.profiles where id = new.author_id;
  new.author_uid := v_uid;
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists trg_comment_snapshot_uid on public.comments;
create trigger trg_comment_snapshot_uid
  before insert on public.comments
  for each row execute procedure public.comment_snapshot_uid();

-- ============ 8. 管理列表 RPC（维持原样，附带邮箱认证等） ============
create or replace function public.admin_list_users()
returns table (
  id uuid,
  uid integer,
  email text,
  username text,
  nickname text,
  gender text,
  role text,
  status text,
  ban_until timestamptz,
  email_confirmed boolean,
  last_sign_in_at timestamptz,
  created_at timestamptz
)
language sql security definer set search_path = public
as $$
  select p.id, p.uid, p.email, p.username, p.nickname, p.gender, p.role, p.status,
         p.ban_until,
         (u.email_confirmed_at is not null) as email_confirmed,
         u.last_sign_in_at,
         p.created_at
  from public.profiles p
  left join auth.users u on u.id = p.id
  where exists (
    select 1 from public.profiles me
    where me.id = auth.uid() and me.role in ('owner','admin')
  )
  order by p.uid nulls last;
$$;
grant execute on function public.admin_list_users() to authenticated;

-- ============ 9. 已删除 uid 列表 RPC（含回调状态 + 残留评论数） ============
create or replace function public.admin_list_deleted_uids()
returns table (
  uid integer,
  note text,
  deleted_at timestamptz,
  recycled boolean,
  remaining_comments bigint
)
language sql security definer set search_path = public
as $$
  select d.uid, d.note, d.deleted_at, d.recycled,
         (select count(*) from public.comments c where c.author_uid = d.uid) as remaining_comments
  from public.deleted_uids d
  where exists (
    select 1 from public.profiles me
    where me.id = auth.uid() and me.role in ('owner','admin')
  )
  order by d.uid;
$$;
grant execute on function public.admin_list_deleted_uids() to authenticated;

-- ============ 10. 确认结果 ============
select 'comments.author_uid' as obj, count(*) from information_schema.columns where table_schema='public' and table_name='comments' and column_name='author_uid'
union all
select 'deleted_uids table', count(*) from information_schema.tables where table_schema='public' and table_name='deleted_uids'
union all
select 'recycled column', count(*) from information_schema.columns where table_schema='public' and table_name='deleted_uids' and column_name='recycled';
