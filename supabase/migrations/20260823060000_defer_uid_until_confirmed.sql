-- 91taffy.com 方案A：uid 延迟到邮箱验证后才分配（2026-08-23）
-- 目的：注册时不再立即建 profiles/发 uid，杜绝「假邮箱刷注册占位 uid」。
-- 机制：
--   1. handle_new_user 改为：仅当 email_confirmed_at 非空时才建 profiles 并发 uid（幂等，已存在则跳过）
--   2. 保留 after insert on auth.users 触发器（service_role 建号 insert 即已确认 → 立即建号）
--   3. 新增 after update of email_confirmed_at on auth.users 触发器（普通用户点验证链接后 → 自动建号发 uid）
--   4. 新增 ensure_profile() RPC：前端登录成功兜底补建（防触发器偶发未触发，仅允许给当前登录用户建）
-- 站长认定：第一个完成邮箱验证并建出 profiles 的用户 = uid0/owner（真站长必会验证自己的邮箱）
-- 运行方式：Supabase 控制台 -> SQL Editor -> 粘贴执行。幂等，可重复执行。

-- ============ 1. 改写建号函数：未验证不建、已存在不建 ============
create or replace function public.handle_new_user()
returns trigger as $$
declare
  v_email text;
  v_uid integer;
  v_role text;
begin
  -- 未验证邮箱（email_confirmed_at 为空）一律不建 profiles、不占 uid
  if new.email_confirmed_at is null then
    return new;
  end if;
  -- 幂等：已有 profiles 则跳过（防重复触发/重复发 uid）
  if exists (select 1 from public.profiles where id = new.id) then
    return new;
  end if;
  v_email := lower(coalesce(new.email, ''));
  -- 首个建号者 = 站长（uid0 / owner）
  if not exists (select 1 from public.profiles) then
    v_uid := 0;
    v_role := 'owner';
  else
    v_uid := nextval('public.uid_seq');
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

-- ============ 2. 保留 insert 触发器（service_role 建号立即建） ============
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ============ 3. 新增：邮箱确认成功后自动建号发 uid ============
drop trigger if exists on_auth_user_confirmed on auth.users;
create trigger on_auth_user_confirmed
  after update of email_confirmed_at on auth.users
  for each row execute procedure public.handle_new_user();

-- ============ 4. 新增：登录成功兜底补建函数（防触发器偶发未触发） ============
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
  -- 仅允许给当前登录用户补建
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
    v_uid := nextval('public.uid_seq');
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
