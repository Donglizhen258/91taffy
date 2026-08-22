-- 91taffy.com 特殊账号工具函数（2026-08-23）
-- 供 migrations/20260823040000_special_accounts.sql 调用：用 service_role 建号并免邮箱验证。
-- 独立文件，方便重复执行与维护。

-- 创建或更新一个 auth 用户，并标记 email 已确认（免邮箱验证登录）
create or replace function public.create_or_update_auth_user(
  p_email text,
  p_password text,
  p_username text,
  p_nickname text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_meta jsonb;
  v_existing_id uuid;
begin
  v_meta := jsonb_build_object('username', p_username, 'nickname', p_nickname);

  -- 已存在则更新密码并确认邮箱，不重复建号
  select id into v_existing_id
  from auth.users
  where lower(email) = lower(p_email)
  limit 1;

  if v_existing_id is not null then
    update auth.users
    set encrypted_password = crypt(p_password, gen_salt('bf')),
        email_confirmed_at = coalesce(email_confirmed_at, now()),
        confirmed_at = coalesce(confirmed_at, now()),
        raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) || v_meta,
        updated_at = now()
    where id = v_existing_id;
    return 'updated:' || v_existing_id::text;
  end if;

  -- 新建
  v_user_id := gen_random_uuid();
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, invited_at, confirmation_token, confirmation_sent_at,
    recovery_token, recovery_sent_at, email_change_token_new, email_change,
    email_change_sent_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
    is_super_admin, created_at, updated_at, phone, phone_confirmed_at,
    phone_change, phone_change_token, phone_change_sent_at, confirmed_at,
    email_change_token_current, email_change_confirm_status, banned_until,
    reauthentication_token, reauthentication_sent_at, is_sso_user, deleted_at,
    is_anonymous
  ) values (
    '00000000-0000-0000-0000-000000000000',
    v_user_id, 'authenticated', 'authenticated', lower(p_email), crypt(p_password, gen_salt('bf')),
    now(), now(), '', now(),
    '', null, '', '', null,
    null, '{}'::jsonb, v_meta,
    false, now(), now(), null, null,
    null, '', null, now(),
    '', 'verified', null,
    '', null, false, null,
    false
  );

  return 'created:' || v_user_id::text;
end;
$$;

-- 权限：允许 postgres 角色调用（SQL Editor 用 postgres 身份执行）
grant execute on function public.create_or_update_auth_user(text, text, text, text) to postgres;
