-- ============================================================
-- 91taffy.com 修复头像存储桶 (2026-08-23)
-- 背景：生产库 avatars / comment-images 两个存储桶都不存在（Bucket not found），
--       之前的建桶脚本 20260822120000 可能没在生产库执行成功
-- 解决：在 Supabase 控制台 SQL Editor 执行本文件
--       先看下方「建桶」两段，若桶已存在则 on conflict 会安全跳过，可重复执行
-- ============================================================

-- ============ 1. 建桶（可重复执行，幂等） ============
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars', 'avatars', true, 2097152, ARRAY['image/jpeg','image/png','image/webp']),
  ('comment-images', 'comment-images', true, 5242880, ARRAY['image/jpeg','image/png','image/gif','image/webp'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- ============ 2. Storage RLS 策略（可重复执行） ============
drop policy if exists "public read avatars" on storage.objects;
drop policy if exists "users upload own avatar" on storage.objects;
drop policy if exists "users update own avatar" on storage.objects;
drop policy if exists "users delete own avatar" on storage.objects;
drop policy if exists "public read comment-images" on storage.objects;
drop policy if exists "auth insert comment-images" on storage.objects;
drop policy if exists "auth delete own comment-images" on storage.objects;

-- avatars：所有人可读
create policy "public read avatars"
  on storage.objects for select
  using ( bucket_id = 'avatars' );

-- avatars：登录用户只能上传到自己的路径 avatars/{自己uid}/*
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

-- comment-images：所有人可读
create policy "public read comment-images"
  on storage.objects for select
  using ( bucket_id = 'comment-images' );

-- comment-images：登录用户可上传
create policy "auth insert comment-images"
  on storage.objects for insert
  with check (
    bucket_id = 'comment-images'
    and auth.role() = 'authenticated'
  );

-- comment-images：本人可删自己的评论图（owner 可删全部）
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

-- ============ 3. 验证（执行下面这行应返回两行） ============
-- select id, name, public from storage.buckets where id in ('avatars','comment-images');
