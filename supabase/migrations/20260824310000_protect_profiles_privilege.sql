-- 91taffy.com 安全加固：封堵 profiles 提权漏洞（2026-08-24）
-- 背景：profiles 表 RLS 策略 "auth update own profile" 用 using(auth.uid()=id) 只限制
--       「只能改自己的行」，但没有限制「能改哪些列」。实测普通用户可 update 自己
--       role='owner' 提权成站长，也可 status='active' 自我解封、改 uid 冒用他人身份。
-- 方案：加 BEFORE INSERT/UPDATE 触发器，非 owner/admin 的普通用户只能改昵称/头像/简介等
--       资料列，禁止改动 role/status/uid/email/username/ban_until 等敏感列。
-- 运行方式：psycopg2 直连生产库执行，幂等可重复执行。

-- ============================================================
-- 1. 保护触发器：普通用户禁止改敏感列（owner/admin 不受限）
-- ============================================================
create or replace function public.protect_profile_privileged_columns()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
  v_role text;
begin
  -- 系统触发器（auth.uid() 为空，如 handle_new_user 建号）直接放行
  if auth.uid() is null then
    return new;
  end if;

  select role into v_role from public.profiles where id = auth.uid();

  -- 站长/管理员：允许改任意列（含封禁、改角色、改 uid）
  if v_role in ('owner','admin') then
    return new;
  end if;

  -- 普通用户：禁止修改敏感列（role/status/uid/email/username/ban_until）
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

drop trigger if exists trg_protect_profile_privileged on public.profiles;
create trigger trg_protect_profile_privileged
  before update on public.profiles
  for each row execute procedure public.protect_profile_privileged_columns();

-- ============================================================
-- 2. INSERT 防护：普通用户直接插入自己 profile 时，强制 role=user/status=active/ban_until=null
--    （防止绕过触发器逻辑、在 profiles 缺失时直接 insert 一条 owner 记录）
-- ============================================================
create or replace function public.force_profile_defaults_on_insert()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
  v_role text;
begin
  if auth.uid() is null then
    return new;  -- 系统触发器（handle_new_user / ensure_profile）走业务逻辑
  end if;

  select role into v_role from public.profiles where id = auth.uid();
  if v_role in ('owner','admin') then
    return new;
  end if;

  -- 普通用户插入：强制普通身份，禁止 self-insert 提权
  new.role := 'user';
  new.status := 'active';
  new.ban_until := null;
  return new;
end;
$$;

drop trigger if exists trg_force_profile_defaults on public.profiles;
create trigger trg_force_profile_defaults
  before insert on public.profiles
  for each row execute procedure public.force_profile_defaults_on_insert();
