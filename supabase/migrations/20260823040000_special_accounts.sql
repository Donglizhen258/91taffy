-- 91taffy.com 特殊账号（站内管家 / test01）创建脚本 v2（2026-08-23）
-- v2 说明（替代 v1 的 auth.users 直插方案，那个方案不同 Supabase 版本字段易崩）：
--   改成「先正常注册，再 SQL 确认邮箱」的稳妥路子：
--     1. 先在网站注册表单上手动注册两个账号（邮箱可随便填，收不到信没关系）
--     2. 再执行本脚本：把两个号的邮箱标记为已确认（免邮箱验证直接登录）
--     3. 把「站内管家」账号昵称改成中文（test01 保持原名）
--   权限与普通用户一致（role=user），登录可用「账号/邮箱 + 密码」。
-- 运行方式：Supabase 控制台 -> SQL Editor -> 粘贴执行。可重复执行，幂等。

-- ============ 1. 把特殊号的邮箱标记为已确认（免邮箱验证登录） ============
update auth.users
set email_confirmed_at = coalesce(email_confirmed_at, now()),
    confirmed_at      = coalesce(confirmed_at, now())
where lower(email) in ('zhanding@91taffy.com', 'test01@91taffy.com');

-- ============ 2. 把「站内管家」昵称改成中文 ============
update public.profiles p
set nickname = '站内管家',
    bio = case when p.bio is null or p.bio = '' then '站内管家，负责站点日常事务喵' else p.bio end
from auth.users u
where u.id = p.id
  and lower(u.email) = 'zhanding@91taffy.com'
  and p.nickname is distinct from '站内管家';

-- ============ 3. 确认结果 ============
select p.uid, u.email, p.username, p.nickname, p.role, p.status,
       u.email_confirmed_at is not null as email_confirmed
from auth.users u
left join public.profiles p on p.id = u.id
where lower(u.email) in ('zhanding@91taffy.com', 'test01@91taffy.com')
order by p.uid nulls last;
