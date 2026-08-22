-- 91taffy.com 个人动态网站 数据库建表脚本 v2 (Supabase / PostgreSQL)
-- 运行方式：Supabase 控制台 -> SQL Editor -> 粘贴执行
-- 功能：每页通用评论区 + 照片评论 + 塔菲表情 + 邮箱注册登录(uid/昵称/密码/性别) + 站长/管理员权限体系

-- ============================================================
-- 0. 扩展：uid 自增序列
-- uid 方案：序列从 1 开始正常递增（PostgreSQL 不允许 start 0）
-- uid0 是特殊存在：站长（1301535058@qq.com）注册时由触发器单独赋予 uid=0，不走序列
-- uid1 = 第一个管理员（maxdong0404@163.com）从序列拿到 1
-- 后续普通用户从 uid2 起递增
-- ============================================================
create sequence if not exists public.uid_seq start 1;
-- 兜底：若之前误建过 start 0 的旧序列，重置为从 1 开始
alter sequence public.uid_seq restart with 1;

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
--    二级评论：parent_id 指向一级评论；reply_to 记录回复对象昵称
--    like_count：点赞数（由 comment_likes 触发器维护）
-- ============================================================
create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  page_id text not null,                     -- 页面标识：home/gallery/某文章slug
  author_id uuid references public.profiles(id) on delete set null,
  content text not null,
  image_url text default '',                 -- 评论附带照片（压缩后上传到Storage）
  parent_id uuid references public.comments(id) on delete cascade,  -- 二级评论归属
  reply_to text default '',                  -- 回复对象昵称
  like_count integer not null default 0,     -- 点赞数
  created_at timestamptz default now() not null
);
create index if not exists idx_comments_page on public.comments(page_id, created_at desc);
create index if not exists idx_comments_parent on public.comments(parent_id);
create index if not exists idx_comments_page_likes on public.comments(page_id, like_count desc);

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
-- 删除规则（2026-08-23 升级）：本人可删自己的评论；站长/管理员可删任意；楼主可删自己一级评论下的二级评论
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
    or exists (
      select 1 from public.comments parent
      where parent.id = comments.parent_id
        and parent.author_id = auth.uid()
    )
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
-- 站长认定机制（不依赖邮箱，防止换绑邮箱导致权限丢失/被冒领）：
--   - 第一个注册的用户 = 站长：uid=0 且 role=owner（uid0 特殊存在，不走序列）
--   - 之后注册的用户 uid 从序列递增（1、2、3...），role=user
--   - 管理员不靠邮箱识别，由站长在管理面板里手动任命
-- 站长换绑邮箱不影响 uid0 身份；即使有人抢注同邮箱，也拿不到 uid0
-- ============================================================
create or replace function public.handle_new_user()
returns trigger as $$
declare
  v_email text;
  v_uid integer;
  v_role text;
begin
  v_email := lower(coalesce(new.email, ''));
  -- 判断是否已有任何用户：若无则当前注册者是站长（uid0）
  if not exists (select 1 from public.profiles) then
    v_uid := 0;
    v_role := 'owner';
  else
    v_uid := nextval('public.uid_seq');
    v_role := 'user';
  end if;
  insert into public.profiles (id, uid, email, username, nickname, gender, role, status)
  values (
    new.id,
    v_uid,
    nullif(v_email, ''),
    coalesce(new.raw_user_meta_data->>'username', 'user_' || substr(new.id::text, 1, 8)),
    coalesce(new.raw_user_meta_data->>'nickname', new.raw_user_meta_data->>'username'),
    coalesce(new.raw_user_meta_data->>'gender', '保密'),
    v_role,
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
-- 10. 说明：站长/管理员不靠邮箱硬编码
-- 站长 = 第一个注册者（uid0）
-- 管理员 = 站长在管理面板中手动任命（前端 setRole 功能）
-- 若需手动指定，可用下面语句（把某 uid 设为站长/管理员，谨慎执行）：
--   update public.profiles set role='owner' where uid=0;
--   update public.profiles set role='admin' where uid=1;
-- ============================================================-- 11. 评论频控辅助表（防刷）
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

-- ============================================================
-- 12. 点赞表 comment_likes（2026-08-23 追加）
-- (comment_id, user_id) 复合主键防重复点赞
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

-- 点赞计数同步触发器
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
-- 13. Storage 桶（2026-08-22 追加）
-- 头像桶 avatars、评论照片桶 comment-images
-- 修复 Bucket not found 报错。完整版本见同目录 migrations/20260822120000_create_storage_buckets.sql
-- ============================================================
