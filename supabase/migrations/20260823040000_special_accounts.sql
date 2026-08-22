-- 91taffy.com 特殊账号（站内管家 / test01）确认邮箱脚本 v2（2026-08-23）
-- 使用前提：
--   1. 先在网站上用注册表单注册两个账号（邮箱随便填，收不到信没关系）：
--        zhanding@91taffy.com  密码 Dongli*2026*   （站内管家）
--        test01@91taffy.com    密码 Test*2026*     （test01）
--   2. 再执行本脚本：把两个号的邮箱标记为已确认（免邮箱验证直接登录）
--      + 把「站内管家」昵称改成中文（test01 保持原名）
--   3. 权限与普通用户一致（role=user），登录可用「账号/邮箱 + 密码」。
-- 本脚本只做 update，不直插 auth.users，不依赖 pgcrypto，幂等可重复执行。

-- ============ 0. 删除之前遗留的坏函数（含 gen_salt 调用，正是报错元凶） ============
drop function if exists public.create_or_update_auth_user(text, text, text, text);
drop function if exists public.create_or_update_auth_user(text, text, text);
drop function if exists public.create_or_update_auth_user(text, text);

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
-- 期望：两个号都出现，email_confirmed = true
select p.uid, u.email, p.username, p.nickname, p.role, p.status,
       u.email_confirmed_at is not null as email_confirmed
from auth.users u
left join public.profiles p on p.id = u.id
where lower(u.email) in ('zhanding@91taffy.com', 'test01@91taffy.com')
order by p.uid nulls last;
