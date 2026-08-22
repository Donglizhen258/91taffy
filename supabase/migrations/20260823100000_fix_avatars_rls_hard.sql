-- ============================================================
-- 91taffy.com 头像上传 RLS 硬修复（2026-08-23）
-- 症状：前端报 "new row violates row-level security policy"
-- 根因：storage.objects 上的 insert 策略在生产库缺失 / 残留旧策略没清干净
-- 用法：Supabase 控制台 → SQL Editor → 整段粘贴执行（不要只跑一半）
-- 幂等：可重复执行，不会影响已有数据
-- ============================================================

-- ============ 1. 建桶（幂等） ============
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars', 'avatars', true, 2097152, ARRAY['image/jpeg','image/png','image/webp']),
  ('comment-images', 'comment-images', true, 5242880, ARRAY['image/jpeg','image/png','image/gif','image/webp'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- ============ 2. 清空 storage.objects 上所有 avatars/comment 相关旧策略 ============
-- 用动态 SQL 兜底：无论旧策略叫什么名字（含大小写差异），全部 drop，避免残留别名导致 create 失败
do $$
declare r record;
begin
  for r in
    select policyname
    from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and (policyname ilike '%avatar%' or policyname ilike '%comment%')
  loop
    execute format('drop policy if exists %I on storage.objects', r.policyname);
  end loop;
end $$;

-- ============ 3. 重建策略（官方推荐写法） ============

-- avatars：所有人可读
create policy "public read avatars"
  on storage.objects for select to anon, authenticated
  using ( bucket_id = 'avatars' );

-- avatars：登录用户只能上传到 avatars/{自己uid}/*
create policy "users upload own avatar"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- avatars：登录用户只能改自己的头像
create policy "users update own avatar"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- avatars：登录用户只能删自己的头像
create policy "users delete own avatar"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- comment-images：所有人可读
create policy "public read comment-images"
  on storage.objects for select to anon, authenticated
  using ( bucket_id = 'comment-images' );

-- comment-images：登录用户可上传
create policy "auth insert comment-images"
  on storage.objects for insert to authenticated
  with check ( bucket_id = 'comment-images' );

-- comment-images：本人可删自己的评论图（owner 可删全部）
create policy "auth delete own comment-images"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'comment-images'
    and (
      (storage.foldername(name))[1] = auth.uid()::text
      or exists (
        select 1 from public.profiles p
        where p.id = auth.uid() and p.role = 'owner'
      )
    )
  );

-- ============ 4. 验证（执行后应看到下面结果） ============
-- 4.1 桶：应返回 avatars / comment-images 两行
select id, name, public, file_size_limit from storage.buckets where id in ('avatars','comment-images');

-- 4.2 策略：应返回 7 行（4 条 avatars + 3 条 comment-images）
select policyname, cmd, roles::text
from pg_policies
where schemaname = 'storage' and tablename = 'objects'
  and (policyname ilike '%avatar%' or policyname ilike '%comment%')
order by policyname;
