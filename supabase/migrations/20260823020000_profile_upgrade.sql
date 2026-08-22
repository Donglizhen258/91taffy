-- 91taffy.com 用户资料升级：详细资料 + 封禁（2026-08-23）
-- 运行方式：Supabase 控制台 -> SQL Editor -> 粘贴执行（或随 Git 集成自动迁移）
-- 全部语句幂等，可重复执行

-- ============================================================
-- 1. profiles 表新增：
--    birthday  —— 生日（date），前端据此自动算星座
--    qq        —— QQ 号
--    ban_until —— 封禁截止时间（null=未封禁，infinity=永久封禁）
--    （bio 自我介绍字段 v2 已有，无需重复添加）
-- ============================================================
alter table public.profiles add column if not exists birthday date;
alter table public.profiles add column if not exists qq text default '';
alter table public.profiles add column if not exists ban_until timestamptz;

-- 兼容旧数据：若之前用 status='banned' 封禁但无 ban_until，统一视为永久封禁
update public.profiles set ban_until = 'infinity'
  where status = 'banned' and ban_until is null;
