-- 91taffy.com 个人动态网站 数据库建表脚本 v2 (Supabase / PostgreSQL)
-- 运行方式：Supabase 控制台 -> SQL Editor -> 粘贴执行
-- 功能：每页通用评论区 + 照片评论 + 塔菲表情 + 邮箱注册登录(uid/昵称/密码/性别) + 站长/管理员权限体系

-- ============================================================
-- 0. 扩展：uid 自增序列
-- uid 从 1 开始，uid1 = 第一个管理员（maxdong0404@163.com）
-- uid 分配：站长会拿到最小的可用 uid（含 uid1），后续注册者递增
-- ============================================================
create sequence if not exists public.uid_seq start 1;

-- ============================================================
-- 1. 用户资料表（含 uid / 角色 / 状态 / 性别）
-- ============================================================
create table if not exists public.profiles (
  id uuid references auth.users on delete cascade not null primary key,
  uid integer unique not null default nextval('public.uid_seq'),
  email text unique,                         -- 绑定邮箱
  username text unique,                      -- 登录名
  nickname text,                             -- 展示昵称
  gender text default '保密' check (gender in ('男','女','保密')),
  role text not null default 'user' check (role in ('owner','admin','user')),
  status text not null default 'active' check (status in ('active','banned')),
  bio text default '',
  avatar_url text default '',
  created_at timestamptz default now() not null
);
comment on table public.profiles is '用户资料，uid自增，role=owner站长/admin管理员/user普通用户，status=active正常/banned封禁';

-- ============================================================
-- 2. 图片表（画廊）
-- ============================================================
create table if not exists public.images (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text default '',
  url text not null,
  author_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now() not null
);

-- ============================================================
-- 3. 通用评论表（每页通用，page_id 定位页面）
-- ============================================================
create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  page_id text not null,                     -- 页面标识：home/gallery/某文章slug
  author_id uuid references public.profiles(id) on delete set null,
  content text not null,
  image_url text default '',                 -- 评论附带照片（压缩后上传到Storage）
  created_at timestamptz default now() not null
);
create index if not exists idx_comments_page on public.comments(page_id, created_at desc);

-- ============================================================
-- 4. 文章表
-- ============================================================
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

-- ============================================================
-- 5. 留言表
-- ============================================================
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  author_id uuid references public.profiles(id) on delete set null,
  author_name text not null default '游客',
  content text not null,
  created_at timestamptz default now() not null
);

-- ============================================================
-- 6. 小游戏排行榜表
-- ============================================================
create table if not exists public.scores (
  id uuid primary key default gen_random_uuid(),
  game text not null,
  player_name text not null default '匿名',
  score integer not null default 0,
  created_at timestamptz default now() not null
);

-- ============================================================
-- 7. 其他索引
-- ============================================================
create index if not exists idx_images_created on public.images(created_at desc);
create index if not exists idx_articles_created on public.articles(created_at desc);
create index if not exists idx_messages_created on public.messages(created_at desc);
create index if not exists idx_scores_game on public.scores(game, score desc);

-- ============================================================
-- 8. 行级安全策略 (RLS)
-- ============================================================
alter table public.articles enable row level security;
alter table public.images enable row level security;
alter table public.comments enable row level security;
alter table public.messages enable row level security;
alter table public.profiles enable row level security;
alter table public.scores enable row level security;

-- 图片：所有人可读；登录用户可上传；本人可删
create policy "public read images" on public.images
  for select using (true);
create policy "auth insert images" on public.images
  for insert with check (auth.uid() = author_id);
create policy "auth delete own images" on public.images
  for delete using (auth.uid() = author_id);

-- 评论：所有人可读；登录且未封禁用户可发表；本人/站长/管理员可删
create policy "public read comments" on public.comments
  for select using (true);
create policy "auth insert comments" on public.comments
  for insert with check (
    auth.uid() = author_id
    and exists (select 1 from public.profiles p where p.id = auth.uid() and p.status = 'active')
  );
create policy "auth delete comments" on public.comments
  for delete using (
    auth.uid() = author_id
    or exists (select 1 from public.profiles p
               where p.id = auth.uid() and p.role in ('owner','admin'))
  );

-- 文章：所有人可读已发布；站长/管理员可管理
create policy "public read published articles" on public.articles
  for select using (published = true or auth.uid() = author_id);
create policy "auth insert articles" on public.articles
  for insert with check (
    exists (select 1 from public.profiles p
            where p.id = auth.uid() and p.role in ('owner','admin'))
  );
create policy "auth update articles" on public.articles
  for update using (
    auth.uid() = author_id
    or exists (select 1 from public.profiles p
               where p.id = auth.uid() and p.role in ('owner','admin'))
  );

-- 留言：所有人可读；登录用户可留言
create policy "public read messages" on public.messages
  for select using (true);
create policy "auth insert messages" on public.messages
  for insert with check (auth.uid() = author_id);

-- 用户资料：所有人可读；本人可更新；站长/管理员可封禁/改角色
create policy "public read profiles" on public.profiles
  for select using (true);
create policy "auth update own profile" on public.profiles
  for update using (auth.uid() = id);
create policy "auth insert own profile" on public.profiles
  for insert with check (auth.uid() = id);
-- 管理员/站长更新他人资料（封禁、任命管理员、改角色）
create policy "admin update profiles" on public.profiles
  for update using (
    exists (select 1 from public.profiles p
            where p.id = auth.uid() and p.role in ('owner','admin'))
  );

-- 排行榜：所有人可读；所有人可提交分数
create policy "public read scores" on public.scores
  for select using (true);
create policy "public insert scores" on public.scores
  for insert with check (true);

-- ============================================================
-- 9. 触发器：注册时自动建资料
-- uid1 绑定第一个管理员邮箱 maxdong0404@163.com → role=admin
-- 站长邮箱 1301535058@qq.com → role=owner（由雏草姬注册时自动成为站长）
-- 其余新用户 → role=user
-- ============================================================
create or replace function public.handle_new_user()
returns trigger as $$
declare
  v_email text;
begin
  v_email := lower(coalesce(new.email, ''));
  insert into public.profiles (id, uid, email, username, nickname, gender, role, status)
  values (
    new.id,
    nextval('public.uid_seq'),
    nullif(v_email, ''),
    coalesce(new.raw_user_meta_data->>'username', 'user_' || substr(new.id::text, 1, 8)),
    coalesce(new.raw_user_meta_data->>'nickname', new.raw_user_meta_data->>'username'),
    coalesce(new.raw_user_meta_data->>'gender', '保密'),
    case
      when v_email = '1301535058@qq.com' then 'owner'
      when v_email = 'maxdong0404@163.com' then 'admin'
      else 'user'
    end,
    'active'
  );
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ============================================================
-- 10. 手动设定站长/管理员（备用，若注册邮箱不匹配时执行）
-- 把已经注册的这两个邮箱升级为站长/管理员
-- ============================================================
update public.profiles set role = 'owner'
  where email = '1301535058@qq.com' and role <> 'owner';
update public.profiles set role = 'admin'
  where email = 'maxdong0404@163.com' and role <> 'admin';

-- ============================================================
-- 11. 评论频控辅助表（防刷）
-- 记录每条评论发布时间，用于每分钟/每天限次
-- ============================================================
create table if not exists public.comment_log (
  id bigint generated always as identity primary key,
  author_id uuid references public.profiles(id) on delete cascade,
  created_at timestamptz default now() not null
);
create index if not exists idx_comment_log_author on public.comment_log(author_id, created_at desc);
alter table public.comment_log enable row level security;
create policy "auth insert comment_log" on public.comment_log
  for insert with check (auth.uid() = author_id);
create policy "auth read own comment_log" on public.comment_log
  for select using (auth.uid() = author_id);
