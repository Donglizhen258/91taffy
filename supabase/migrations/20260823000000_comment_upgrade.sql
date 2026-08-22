-- 91taffy.com 评论区升级：二级评论 + 点赞 + 楼层 + 排序（2026-08-23）
-- 运行方式：Supabase 控制台 -> SQL Editor -> 粘贴执行（或随 Git 集成自动迁移）
-- 全部语句幂等，可重复执行

-- ============================================================
-- 1. comments 表新增：
--    parent_id  —— 二级评论归属的一级评论 id（null = 一级评论）
--    reply_to   —— 回复对象的昵称（用于展示「回复 @某人」）
--    like_count —— 点赞数（由触发器自动维护，便于排序）
-- ============================================================
alter table public.comments add column if not exists parent_id uuid references public.comments(id) on delete cascade;
alter table public.comments add column if not exists reply_to text default '';
alter table public.comments add column if not exists like_count integer not null default 0;

create index if not exists idx_comments_parent on public.comments(parent_id);
create index if not exists idx_comments_page_likes on public.comments(page_id, like_count desc);

-- ============================================================
-- 2. 点赞表 comment_likes
--    (comment_id, user_id) 复合主键，天然防止同一用户重复点赞
-- ============================================================
create table if not exists public.comment_likes (
  comment_id uuid references public.comments(id) on delete cascade not null,
  user_id uuid references public.profiles(id) on delete cascade not null,
  created_at timestamptz default now() not null,
  primary key (comment_id, user_id)
);
alter table public.comment_likes enable row level security;
create policy "public read comment_likes" on public.comment_likes
  for select using (true);
create policy "auth insert comment_likes" on public.comment_likes
  for insert with check (auth.uid() = user_id);
create policy "auth delete comment_likes" on public.comment_likes
  for delete using (auth.uid() = user_id);

-- ============================================================
-- 3. 点赞计数同步触发器
--    insert/delete comment_likes 时自动 +/- comments.like_count
-- ============================================================
create or replace function public.sync_comment_like_count()
returns trigger as $$
begin
  if tg_op = 'INSERT' then
    update public.comments set like_count = like_count + 1 where id = new.comment_id;
    return new;
  elsif tg_op = 'DELETE' then
    update public.comments set like_count = greatest(like_count - 1, 0) where id = old.comment_id;
    return old;
  end if;
  return null;
end;
$$ language plpgsql security definer;

drop trigger if exists trg_comment_likes_sync on public.comment_likes;
create trigger trg_comment_likes_sync
  after insert or delete on public.comment_likes
  for each row execute procedure public.sync_comment_like_count();

-- ============================================================
-- 4. 更新评论删除策略：
--    - 本人可删自己的评论（一级/二级）
--    - 站长/管理员可删任意评论
--    - 一级评论的楼主可删自己楼内的二级评论（parent_id = 自己的一级评论）
--    删除一级评论时，parent_id 的 on delete cascade 自动级联删除其下所有二级评论
-- ============================================================
drop policy if exists "auth delete comments" on public.comments;
create policy "auth delete comments" on public.comments
  for delete using (
    auth.uid() = author_id
    or exists (select 1 from public.profiles p
               where p.id = auth.uid() and p.role in ('owner','admin'))
    or exists (
      select 1 from public.comments parent
      where parent.id = comments.parent_id
        and parent.author_id = auth.uid()
    )
  );
