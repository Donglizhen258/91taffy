-- 91taffy.com uid 序列修复（2026-08-23）
-- 症状：新注册账号 uid 跳号（比如站长 uid0 之后，第二个注册账号却拿到 uid3，uid1/uid2 缺失），
--       或注册时 profiles 插入失败导致注册整体回滚、后续登录不上。
-- 根因：建表脚本里 `alter sequence public.uid_seq restart with 1;` 被重复执行，
--       把 uid 序列强行拉回 1，导致新注册 nextval 拿到已存在的 uid1/uid2，
--       触发 profiles.uid 唯一冲突 -> 注册事务回滚 -> 序列值已被消耗（nextval 不回滚）-> 越跳越远。
-- 修复：把序列对齐到当前最大 uid（>0，排除站长 uid0），让下一个注册账号拿到 max(uid)+1。
-- 运行方式：Supabase 控制台 -> SQL Editor -> 粘贴执行。语句幂等，可重复执行。

-- 1. 对齐序列到当前最大 uid
select setval('public.uid_seq',
  coalesce((select max(uid) from public.profiles where uid > 0), 0) + 1,
  false) as uid_seq_next_will_be;

-- 2. 查看当前 uid 分布，确认对齐结果
--    uid=0 是站长；其余按注册顺序递增。若中间有缺口（如缺 1、2），说明历史上有过失败/删除的注册，
--    属正常现象，不影响功能（uid 只需唯一，不必连续）。
select uid, email, username, nickname, role, status, created_at
from public.profiles
order by uid;

-- 3.（可选）若确有「auth.users 有账号但 profiles 缺失」的残留账号导致登录报错，
--    可用下面的查询找出它们：
-- select u.id, u.email, u.created_at
-- from auth.users u
-- left join public.profiles p on p.id = u.id
-- where p.id is null;
