-- 91taffy.com uid 重排：站内管家=1、test01=2（2026-08-23）
-- 背景：之前失败注册消耗了 uid 序列（nextval 不回滚），导致站内管家/test01 拿到 4、5，而 1、2、3 空缺。
--       本站所有表（comments/comment_likes 等）均用 profiles.id（uuid）做外键，没有任何表外键引用 profiles.uid，
--       因此直接改 uid 是安全的，不会破坏评论、点赞等数据。
-- 效果：站内管家 → uid1，test01 → uid2，下个新注册用户从 uid3 起。
-- 运行方式：Supabase 控制台 -> SQL Editor -> 粘贴执行。幂等，可重复执行。

-- ============ 1. 先看当前 uid 分布 ============
select id, uid, email, username, nickname, role from public.profiles order by uid;

-- ============ 2. 清理可能占着 1/2 的孤儿资料（理论上没有，双保险） ============
delete from public.profiles
where uid in (1,2)
  and lower(coalesce(email,'')) not in ('zhanding@91taffy.com','test01@91taffy.com');

-- ============ 3. 站内管家 → uid 1 ============
update public.profiles set uid = 1
where lower(email) = 'zhanding@91taffy.com' and uid is distinct from 1;

-- ============ 4. test01 → uid 2 ============
update public.profiles set uid = 2
where lower(email) = 'test01@91taffy.com' and uid is distinct from 2;

-- ============ 5. 序列对齐：下个新用户从 max(uid)+1 起（当前应为 3） ============
select setval('public.uid_seq',
  coalesce((select max(uid) from public.profiles where uid > 0), 0) + 1,
  false);

-- ============ 6. 确认结果：期望 uid0=站长、uid1=站内管家、uid2=test01 ============
select id, uid, email, username, nickname, role from public.profiles order by uid;
