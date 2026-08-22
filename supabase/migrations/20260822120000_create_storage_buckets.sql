-- ============================================================
-- 91taffy.com Storage Buckets (2026-08-22)
-- 用途：创建头像桶 avatars、评论照片桶 comment-images
-- 错误背景：编辑头像时报 Bucket not found，因为生产库手动建表时
-- 漏建 storage bucket（config.toml 只对本地 supabase 生效）
-- 解决：在迁移脚本里显式创建两个公开桶 + 写入策略
-- ============================================================

-- 1. 头像桶：每人自己路径下读写，公开读
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 2097152, ARRAY['image/jpeg','image/png','image/webp'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- 2. 评论照片桶：所有人公开读，登录用户可上传
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('comment-images', 'comment-images', true, 5242880, ARRAY['image/jpeg','image/png','image/gif','image/webp'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- ============================================================
-- Storage RLS 策略
-- ============================================================

-- 清除可能存在的旧策略，避免重复创建报错
drop policy if exists "public read avatars" on storage.objects;
drop policy if exists "users upload own avatar" on storage.objects;
drop policy if exists "users update own avatar" on storage.objects;
drop policy if exists "users delete own avatar" on storage.objects;

drop policy if exists "public read comment-images" on storage.objects;
drop policy if exists "auth insert comment-images" on storage.objects;
drop policy if exists "auth delete own comment-images" on storage.objects;

-- ===== avatars =====
-- 所有人可读
create policy "public read avatars"
  on storage.objects for select
  using ( bucket_id = 'avatars' );

-- 登录用户只能上传到自己的路径 avatars/{自己uid}/*
create policy "users upload own avatar"
  on storage.objects for insert
  with check (
    bucket_id = 'avatars'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "users update own avatar"
  on storage.objects for update
  using (
    bucket_id = 'avatars'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "users delete own avatar"
  on storage.objects for delete
  using (
    bucket_id = 'avatars'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ===== comment-images =====
-- 所有人可读
create policy "public read comment-images"
  on storage.objects for select
  using ( bucket_id = 'comment-images' );

-- 登录用户可上传（路径不做强制约束，简单自管）
create policy "auth insert comment-images"
  on storage.objects for insert
  with check (
    bucket_id = 'comment-images'
    and auth.role() = 'authenticated'
  );

-- 本人可删自己的评论图（owner 可删全部）
create policy "auth delete own comment-images"
  on storage.objects for delete
  using (
    bucket_id = 'comment-images'
    and (
      auth.role() = 'authenticated'
      and (storage.foldername(name))[1] = auth.uid()::text
      or exists (
        select 1 from public.profiles p
        where p.id = auth.uid() and p.role = 'owner'
      )
    )
  );

-- ============================================================
-- 提示：若生产库已存在 avatars bucket 但报 Bucket not found，
-- 通常是因为 PostgREST / GoTrue 缓存未刷新，
-- 解决：先在 Supabase 控制台 Storage 里手动 check 一下 buckets，
--       必要时点一下 "Confirm" 重新触发 sync
-- 兜底：如 SQL 报错，可分两步在控制台执行
-- ============================================================
