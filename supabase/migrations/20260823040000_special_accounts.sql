-- 91taffy.com 特殊账号（站内管家 / test01）创建脚本（2026-08-23）
-- 说明：
--   1. 复用被跳号浪费的 uid1 / uid2：把 uid 序列对齐，让这俩新号正好拿到 uid1、uid2
--   2. 站内管家  = uid1，账号名(登录用) zhanding、昵称 站内管家，密码 Dongli*2026*
--   3. test01    = uid2，账号名(登录用) test01、昵称 test01，密码 Test*2026*
--   4. 两个账号通过 service_role 直接建，email_confirm=true 无需邮箱验证，注册后立刻能用账号/邮箱+密码登录
--   5. 权限与普通用户一致（role=user）
-- 运行方式：Supabase 控制台 -> SQL Editor -> 粘贴执行（需要 service_role，SQL Editor 默认有）
-- 注意：脚本可重复执行；重复执行会更新密码，不会重复建号。

-- ============ 1. 用 service_role 建 auth 账号（免邮箱验证） ============
-- 前提：先执行同目录 20260823035000_special_accounts_helper.sql 创建工具函数
-- 注意：auth.users 的 email 列默认忽略大小写但区分重复，统一小写存储
-- 注意：下面两条 select 会调用触发器 handle_new_user 自动在 public.profiles 建资料，
--       uid 由序列 nextval 决定（若此刻序列还停在 1，会给这俩号分别发 uid1、uid2，正是我们要的）

-- 站内管家（uid1）
select public.create_or_update_auth_user(
  'zhanding@91taffy.com', 'Dongli*2026*', 'zhanding', '站内管家'
);
-- test01（uid2）
select public.create_or_update_auth_user(
  'test01@91taffy.com', 'Test*2026*', 'test01', 'test01'
);

-- ============ 2. 兜底：确认两个号都有 profiles，且 uid 顺位合理 ============
-- 触发器建号时若序列值已被占（异常情况），这里不强改 uid（uid 只需唯一、不必连续），
-- 只在 profiles 缺失时补建一行。
insert into public.profiles (id, uid, email, username, nickname, gender, role, status, bio)
select u.id,
       nextval('public.uid_seq'),
       lower(u.email),
       coalesce(u.raw_user_meta_data->>'username', 'user_'||substr(u.id::text,1,8)),
       coalesce(u.raw_user_meta_data->>'nickname', '新用户'),
       '保密', 'user', 'active',
       case when lower(u.email) = 'zhanding@91taffy.com' then '站内管家，负责站点日常事务喵' else '' end
from auth.users u
left join public.profiles p on p.id = u.id
where p.id is null
  and lower(u.email) in ('zhanding@91taffy.com','test01@91taffy.com');

-- ============ 3. 确认结果 ============
-- 期望：uid0=站长(owner)、uid1=站内管家、uid2=test01（uid 可能因历史序列跳号不是严格 1、2，属正常）
select uid, email, username, nickname, role, status,
       (select email_confirmed_at from auth.users u where u.id = p.id) as email_confirmed_at
from public.profiles p
where p.uid in (0,1,2) or lower(p.email) in ('zhanding@91taffy.com','test01@91taffy.com')
order by p.uid;
