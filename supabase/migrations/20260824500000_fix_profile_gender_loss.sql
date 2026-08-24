-- 91taffy.com 修复：注册时昵称/性别丢失（2026-08-24）
-- 根因：注册流程用 signInWithOtp(shouldCreateUser:true) 只传邮箱，新建用户 raw_user_meta_data 为空；
--       verifyOtp 通过瞬间触发 on_auth_user_confirmed → handle_new_user 建 profile 读空 metadata，
--       gender 回落默认 '保密'，昵称/username 有时回落 user_xxxx。
--       前端 verifyOtp 之后才 updateUser 补 metadata，晚于 profile 创建。
-- 修复（幂等，可重复执行）：
--   1. ensure_profile 增加 p_gender 参数，从 auth.users 元数据兜底读 gender，不再硬编码 '保密'
--   2. ensure_profile 遇到"已存在但缺性别/昵称"的 profile 时补齐（仅注册瞬间显式传入时，不覆盖用户后来改的资料）
--   3. 存量数据一次性补齐：metadata 有性别但 profile 为 '保密' 的补性别；user_xxx 尾巴的补 username/nickname
-- 执行方式：psycopg2 直连生产库或 Supabase Management API /database/query（curl 文件方式，DDL 用 $$ 包裹）

-- ============================================================
-- 1. 重写 ensure_profile：支持传入 gender，缺失时从 auth.users 元数据兜底
-- ============================================================
create or replace function public.ensure_profile(
  p_id uuid,
  p_email text,
  p_username text default null,
  p_nickname text default null,
  p_gender text default null
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_email text;
  v_uid integer;
  v_role text;
  v_gender text;
  v_nick text;
begin
  if p_id <> auth.uid() then
    return;
  end if;
  v_email := lower(coalesce(p_email, ''));
  v_gender := coalesce(p_gender,
              (select raw_user_meta_data->>'gender' from auth.users where id = p_id),
              '保密');
  v_nick := coalesce(p_nickname,
              (select raw_user_meta_data->>'nickname' from auth.users where id = p_id));
  -- 已存在：仅在注册瞬间（显式传了 p_gender/p_nickname）补齐丢失的性别/昵称，避免覆盖用户后来改的资料
  if exists (select 1 from public.profiles where id = p_id) then
    if p_gender is not null and p_gender in ('男','女') then
      update public.profiles set gender = p_gender
      where id = p_id and (gender is null or gender = '保密');
    end if;
    if v_nick is not null and (p_nickname is not null or p_username is not null) then
      update public.profiles
      set nickname = coalesce(p_nickname, nickname),
          username = coalesce(p_username, username)
      where id = p_id
        and (nickname is null or nickname like 'user\_%' or username like 'user\_%');
    end if;
    return;
  end if;
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
    coalesce(v_nick, p_username),
    v_gender,
    v_role,
    'active'
  );
end;
$$;

grant execute on function public.ensure_profile(uuid, text, text, text, text) to anon, authenticated;

-- ============================================================
-- 2. 存量修复（幂等）：metadata 有性别但 profile 是 '保密' 的补性别
-- ============================================================
update public.profiles p
set gender = u.raw_user_meta_data->>'gender'
from auth.users u
where u.id = p.id
  and p.gender = '保密'
  and u.raw_user_meta_data->>'gender' in ('男','女');

-- ============================================================
-- 3. 存量修复（幂等）：user_xxx 尾巴的补 username/nickname
-- ============================================================
update public.profiles p
set username = coalesce(p.username, u.raw_user_meta_data->>'username', p.username),
    nickname = coalesce(p.nickname, u.raw_user_meta_data->>'nickname', p.nickname)
from auth.users u
where u.id = p.id
  and (
    (p.username like 'user\_%' and u.raw_user_meta_data->>'username' is not null
      and u.raw_user_meta_data->>'username' <> p.username)
    or (p.nickname is null and u.raw_user_meta_data->>'nickname' is not null)
  );
