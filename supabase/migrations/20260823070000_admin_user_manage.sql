-- 91taffy.com 管理后台升级：删除账户 + 重置密码 + 认证状态列表（2026-08-23）
-- 运行方式：Supabase 控制台 -> SQL Editor -> 粘贴执行（或随 Git 集成自动迁移）
-- 全部语句幂等，可重复执行
-- 说明：
--   * 密码不可见：Supabase 密码为 bcrypt 单向哈希，站长无法查看明文，只能「重置」为新密码。
--   * 删除账户：直接删 auth.users 记录，profiles / 点赞 / 评论日志等随外键级联清理；
--     该用户的评论保留但作者显示为「神秘用户」（comments.author_id 外键 on delete set null）。

-- ============ 1. 管理列表 RPC（含认证状态 / 最后登录 / 封禁到期） ============
-- 只有站长/管理员能调用；返回 profiles 关键字段 + auth.users 的认证状态与最后登录时间
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

-- ============ 2. 删除用户 RPC（站长/管理员） ============
-- 校验：仅站长/管理员可删；不能删自己；不能删站长账号
create or replace function public.admin_delete_user(target_id uuid)
returns void
language plpgsql security definer
as $$
declare
  v_me_role text;
begin
  select role into v_me_role from public.profiles where id = auth.uid();
  if v_me_role is null or v_me_role not in ('owner','admin') then
    raise exception '仅站长/管理员可删除用户';
  end if;
  if target_id = auth.uid() then
    raise exception '不能删除自己的账号';
  end if;
  if exists (select 1 from public.profiles where id = target_id and role = 'owner') then
    raise exception '不能删除站长账号';
  end if;
  -- 删 auth.users 会级联删 profiles / comment_likes / comment_log；
  -- comments/images/articles/messages 的 author_id 为 on delete set null，保留内容但作者置空
  delete from auth.users where id = target_id;
end;
$$;
grant execute on function public.admin_delete_user(uuid) to authenticated;

-- ============ 3. 重置密码 RPC（站长/管理员） ============
-- 密码为 bcrypt 单向哈希，后台无法查看明文；本函数把指定用户密码重置为新密码
-- 注意 search_path 需包含 extensions，否则 gen_salt/crypt 找不到（pgcrypto 装在 extensions schema）
create or replace function public.admin_reset_password(target_id uuid, new_password text)
returns void
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_me_role text;
begin
  select role into v_me_role from public.profiles where id = auth.uid();
  if v_me_role is null or v_me_role not in ('owner','admin') then
    raise exception '仅站长/管理员可重置密码';
  end if;
  if exists (select 1 from public.profiles where id = target_id and role = 'owner') then
    raise exception '不能重置站长账号密码';
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
grant execute on function public.admin_reset_password(uuid, text) to authenticated;

-- ============ 4. 确认结果 ============
select proname, pg_get_function_identity_arguments(oid) as args
from pg_proc
where proname in ('admin_list_users','admin_delete_user','admin_reset_password')
order by proname;
