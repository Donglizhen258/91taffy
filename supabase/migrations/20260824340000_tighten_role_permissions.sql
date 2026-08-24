-- 91taffy.com 安全加固：收紧角色权限边界（2026-08-24）
-- 背景：实测发现 P0 越权漏洞——admin 可通过 profiles 直连 update 把自己提权成 owner、
--       把站长降级为 user、封禁其他 admin；admin_delete_user 可删其他 admin；
--       admin_reset_password 可重置其他 admin 密码。根源是之前触发器把 owner/admin 一视同仁放行。
-- 正确权限层级：
--   owner（站长）：全权
--   admin（管理员）：只能管理普通 user（封禁/解封/删除/重置密码），
--                    不能改任何人的 role（任命/取消管理员是 owner 专属），
--                    不能动 owner，不能动其他 admin，不能自我提权/降级。
--   user：只能改自己的昵称/头像/资料。
-- 运行方式：psycopg2 直连生产库执行。幂等可重复执行。

-- ============================================================
-- 1. 重写 profiles 敏感列保护触发器（严格角色边界）
-- ============================================================
create or replace function public.protect_profile_privileged_columns()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
  v_role text;          -- 操作者角色
  v_target_role text;   -- 被修改行当前角色
begin
  -- 系统触发器（auth.uid() 为空，如 handle_new_user 建号）直接放行
  if auth.uid() is null then
    return new;
  end if;

  select role into v_role from public.profiles where id = auth.uid();
  v_target_role := old.role;

  -- owner：全权
  if v_role = 'owner' then
    return new;
  end if;

  -- admin：受限管理
  if v_role = 'admin' then
    -- 不能动 owner
    if v_target_role = 'owner' then
      raise exception '管理员不能修改站长账号喵';
    end if;
    -- 不能动其他 admin（只能改自己的资料）
    if v_target_role = 'admin' and old.id <> auth.uid() then
      raise exception '管理员不能修改其他管理员喵';
    end if;
    -- admin 改自己：只能改资料列，不能改 role/status/uid 等
    if old.id = auth.uid() then
      if new.role is distinct from old.role
         or new.status is distinct from old.status
         or new.uid is distinct from old.uid
         or new.email is distinct from old.email
         or new.username is distinct from old.username
         or new.ban_until is distinct from old.ban_until then
        raise exception '无权修改账号角色、状态或身份信息喵';
      end if;
      return new;
    end if;
    -- admin 改普通 user：只能改 status/ban_until（封禁/解封），不能改 role/uid/email/username
    if new.role is distinct from old.role
       or new.uid is distinct from old.uid
       or new.email is distinct from old.email
       or new.username is distinct from old.username then
      raise exception '管理员无权修改用户角色或身份信息喵';
    end if;
    return new;
  end if;

  -- 普通 user：禁止修改敏感列
  if new.role is distinct from old.role
     or new.status is distinct from old.status
     or new.uid is distinct from old.uid
     or new.email is distinct from old.email
     or new.username is distinct from old.username
     or new.ban_until is distinct from old.ban_until then
    raise exception '无权修改账号角色、状态或身份信息喵';
  end if;

  return new;
end;
$$;

-- ============================================================
-- 2. admin_delete_user：admin 不能删除其他 admin（只能删 user）
--    基于最新版（含 uid 冻结池逻辑）
-- ============================================================
create or replace function public.admin_delete_user(target_id uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_me_role text;
  v_target_role text;
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
  select uid, role, coalesce(nickname, username, '') into v_uid, v_target_role, v_name
    from public.profiles where id = target_id;
  if v_uid is null then
    raise exception '目标用户不存在';
  end if;
  if v_target_role = 'owner' then
    raise exception '不能删除站长账号';
  end if;
  -- admin 不能删除其他 admin（只有 owner 能删 admin）
  if v_me_role = 'admin' and v_target_role = 'admin' then
    raise exception '管理员不能删除其他管理员，仅站长可操作喵';
  end if;
  -- uid 进冻结池（幂等）
  insert into public.deleted_uids (uid, note)
  values (v_uid, coalesce(v_name, ''))
  on conflict (uid) do nothing;
  -- 删除 auth.users（级联清 profiles / comment_likes / comment_log）
  delete from auth.users where id = target_id;
end;
$$;

-- ============================================================
-- 3. admin_reset_password：admin 不能重置其他 admin 密码（只能重置 user）
-- ============================================================
create or replace function public.admin_reset_password(target_id uuid, new_password text)
returns void
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_me_role text;
  v_target_role text;
begin
  select role into v_me_role from public.profiles where id = auth.uid();
  if v_me_role is null or v_me_role not in ('owner','admin') then
    raise exception '仅站长/管理员可重置密码';
  end if;
  select role into v_target_role from public.profiles where id = target_id;
  if v_target_role is null then
    raise exception '目标用户不存在';
  end if;
  if v_target_role = 'owner' then
    raise exception '不能重置站长账号密码';
  end if;
  -- admin 不能重置其他 admin 密码（只有 owner 能）
  if v_me_role = 'admin' and v_target_role = 'admin' then
    raise exception '管理员不能重置其他管理员密码，仅站长可操作喵';
  end if;
  if new_password is null or char_length(new_password) < 6 then
    raise exception '新密码至少 6 位';
  end if;
  update auth.users
  set encrypted_password = crypt(new_password, gen_salt('bf')),
      updated_at = now()
  where id = target_id;
end;
$$;
