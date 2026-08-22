-- 91taffy.com 个人动态网站 数据库建表脚本 (Supabase / PostgreSQL)
-- 运行方式：Supabase 控制台 -> SQL Editor -> 粘贴执行
-- 功能：图像画廊 + 评论区 + 小游戏排行榜 + 留言板 + 用户登录

-- ========== 用户资料表 ==========
create table if not exists public.profiles (
  id uuid references auth.users on delete cascade not null primary key,
  username text unique not null,
  nickname text,
  bio text default '',
  avatar_url text default '',
  created_at timestamptz default now() not null
);

-- ========== 图片表（画廊）==========
create table if not exists public.images (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text default '',
  url text not null,
  author_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now() not null
);

-- ========== 图片评论表 ==========
create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  image_id uuid references public.images(id) on delete cascade not null,
  author_id uuid references public.profiles(id) on delete set null,
  author_name text not null default '游客',
  content text not null,
  created_at timestamptz default now() not null
);

-- ========== 文章表 ==========
create table if not exists public.articles (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  slug text unique,
  content text not null,
  summary text default '',
  cover_url text default '',
  published boolean default false,
  author_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

-- ========== 留言表 ==========
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  author_id uuid references public.profiles(id) on delete set null,
  author_name text not null default '游客',
  content text not null,
  created_at timestamptz default now() not null
);

-- ========== 小游戏排行榜表 ==========
create table if not exists public.scores (
  id uuid primary key default gen_random_uuid(),
  game text not null,
  player_name text not null default '匿名',
  score integer not null default 0,
  created_at timestamptz default now() not null
);

-- ========== 索引 ==========
create index if not exists idx_images_created on public.images(created_at desc);
create index if not exists idx_comments_image on public.comments(image_id, created_at desc);
create index if not exists idx_articles_created on public.articles(created_at desc);
create index if not exists idx_messages_created on public.messages(created_at desc);
create index if not exists idx_scores_game on public.scores(game, score desc);

-- ========== 行级安全策略 (RLS) ==========
alter table public.articles enable row level security;
alter table public.images enable row level security;
alter table public.comments enable row level security;
alter table public.messages enable row level security;
alter table public.profiles enable row level security;
alter table public.scores enable row level security;

-- 图片：所有人可读；登录用户可上传
create policy "public read images" on public.images
  for select using (true);
create policy "auth insert images" on public.images
  for insert with check (auth.uid() = author_id);
create policy "auth delete own images" on public.images
  for delete using (auth.uid() = author_id);

-- 评论：所有人可读；登录用户可发表
create policy "public read comments" on public.comments
  for select using (true);
create policy "auth insert comments" on public.comments
  for insert with check (auth.uid() = author_id);

-- 文章：所有人可读已发布文章；登录用户可发布
create policy "public read published articles" on public.articles
  for select using (published = true or auth.uid() = author_id);
create policy "auth insert own articles" on public.articles
  for insert with check (auth.uid() = author_id);
create policy "auth update own articles" on public.articles
  for update using (auth.uid() = author_id);

-- 留言：所有人可读；登录用户可留言
create policy "public read messages" on public.messages
  for select using (true);
create policy "auth insert messages" on public.messages
  for insert with check (auth.uid() = author_id);

-- 用户资料：所有人可读；本人可更新
create policy "public read profiles" on public.profiles
  for select using (true);
create policy "auth update own profile" on public.profiles
  for update using (auth.uid() = id);
create policy "auth insert own profile" on public.profiles
  for insert with check (auth.uid() = id);

-- 排行榜：所有人可读；所有人可提交分数
create policy "public read scores" on public.scores
  for select using (true);
create policy "public insert scores" on public.scores
  for insert with check (true);

-- ========== 触发器：注册时自动建资料 ==========
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, username, nickname)
  values (new.id, coalesce(new.raw_user_meta_data->>'username', 'user_' || substr(new.id::text, 1, 8)),
          coalesce(new.raw_user_meta_data->>'nickname', new.raw_user_meta_data->>'username'));
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();
