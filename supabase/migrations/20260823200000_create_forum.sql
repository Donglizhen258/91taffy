-- 91taffy.com 塔菲论坛建表脚本（2026-08-23）
-- 运行方式：Supabase 控制台 -> SQL Editor -> 粘贴执行
-- 功能：贴吧式论坛。forum_posts 帖子表（含公告/置顶/加精/配图）
--      forum_replies 回帖表（楼层 + 楼中楼 + 配图 + 点赞）
--      forum_likes 点赞表（防重复点赞）
-- 全部语句幂等，可重复执行

-- ============================================================
-- 1. 帖子表
--    post_type: post=普通帖 / notice=公告贴（强制置顶）
--    is_pinned: 置顶   is_essence: 加精
--    reply_count / last_reply_at: 由触发器维护，列表页排序用
-- ============================================================
create table if not exists public.forum_posts (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  content text not null,
  image_url text default '',                 -- 帖子配图（Storage 公开 URL）
  author_id uuid references public.profiles(id) on delete set null,
  post_type text not null default 'post' check (post_type in ('post','notice')),
  is_pinned boolean not null default false,
  is_essence boolean not null default false,
  reply_count integer not null default 0,
  last_reply_at timestamptz,                 -- 最后回复时间，null=没人回
  created_at timestamptz default now() not null
);
comment on table public.forum_posts is '塔菲论坛帖子：post普通帖/notice公告贴，is_pinned置顶，is_essence加精';

create index if not exists idx_forum_posts_pin_time
  on public.forum_posts (is_pinned desc, last_reply_at desc nulls last);
create index if not exists idx_forum_posts_created
  on public.forum_posts (created_at desc);

-- ============================================================
-- 2. 回帖表（楼层 + 楼中楼）
--    parent_id: null = 主回帖（占楼层）；非null = 楼中楼（某层下的小对话，不占楼层）
--    floor: 主回帖楼层号（从 2 开始，1 楼留给楼主正文，贴吧原味）
--    reply_to: 回复对象昵称（展示「回复 @某人」）
-- ============================================================
create table if not exists public.forum_replies (
  id uuid primary key default gen_random_uuid(),
  post_id uuid references public.forum_posts(id) on delete cascade not null,
  parent_id uuid references public.forum_replies(id) on delete cascade,
  author_id uuid references public.profiles(id) on delete set null,
  content text not null,
  image_url text default '',
  floor integer,
  reply_to text default '',
  like_count integer not null default 0,
  created_at timestamptz default now() not null
);
comment on table public.forum_replies is '塔菲论坛回帖：parent_id为空=主回帖占楼层，非空=楼中楼';

create index if not exists idx_forum_replies_post_floor
  on public.forum_replies (post_id, floor);
create index if not exists idx_forum_replies_post_parent
  on public.forum_replies (post_id, parent_id, created_at);

-- ============================================================
-- 3. 点赞表（复合主键防重复点赞）
-- ============================================================
create table if not exists public.forum_likes (
  reply_id uuid references public.forum_replies(id) on delete cascade not null,
  user_id uuid references public.profiles(id) on delete cascade not null,
  created_at timestamptz default now() not null,
  primary key (reply_id, user_id)
);

-- ============================================================
-- 4. RLS 权限
-- ============================================================
alter table public.forum_posts enable row level security;
alter table public.forum_replies enable row level security;
alter table public.forum_likes enable row level security;

-- 帖子：所有人可读
drop policy if exists "public read forum_posts" on public.forum_posts;
create policy "public read forum_posts" on public.forum_posts
  for select using (true);

-- 回帖：所有人可读
drop policy if exists "public read forum_replies" on public.forum_replies;
create policy "public read forum_replies" on public.forum_replies
  for select using (true);

-- 点赞：所有人可读；本人可赞/取消
drop policy if exists "public read forum_likes" on public.forum_likes;
create policy "public read forum_likes" on public.forum_likes
  for select using (true);
drop policy if exists "auth insert forum_likes" on public.forum_likes;
create policy "auth insert forum_likes" on public.forum_likes
  for insert with check (auth.uid() = user_id);
drop policy if exists "auth delete forum_likes" on public.forum_likes;
create policy "auth delete forum_likes" on public.forum_likes
  for delete using (auth.uid() = user_id);

-- ============================================================
-- 5. 点赞计数同步触发器（同 comment_likes 的设计）
-- ============================================================
create or replace function public.sync_forum_like_count()
returns trigger as $$
begin
  if tg_op = 'INSERT' then
    update public.forum_replies set like_count = like_count + 1 where id = new.reply_id;
    return new;
  elsif tg_op = 'DELETE' then
    update public.forum_replies set like_count = greatest(like_count - 1, 0) where id = old.reply_id;
    return old;
  end if;
  return null;
end;
$$ language plpgsql security definer;

drop trigger if exists trg_forum_likes_sync on public.forum_likes;
create trigger trg_forum_likes_sync
  after insert or delete on public.forum_likes
  for each row execute procedure public.sync_forum_like_count();

-- ============================================================
-- 6. 发帖 RPC（安全写入 + 公告身份切换）
--    p_type: 'post' / 'notice'
--    p_as_assistant: true 时用 uid1「站内管家」当发帖人（仅 owner/admin 可用）
--    公告贴强制置顶，仅 owner/admin 可发
-- ============================================================
create or replace function public.create_forum_post(
  p_title text,
  p_content text,
  p_image_url text default '',
  p_type text default 'post',
  p_as_assistant boolean default false
)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_me uuid;
  v_role text;
  v_new_id uuid;
begin
  if v_uid is null then
    raise exception '请先登录喵';
  end if;

  select id, role into v_me, v_role
    from public.profiles where id = v_uid;
  if v_me is null or v_role not in ('owner','admin','user') then
    raise exception '账号异常，无法发帖喵';
  end if;

  -- 公告贴：仅站长/管理员可发，强制置顶
  if p_type = 'notice' then
    if v_role not in ('owner','admin') then
      raise exception '只有站长/管理员能发布公告喵';
    end if;
    -- 公告可署名自己 或 uid1 网站助手
    if p_as_assistant then
      v_me := (select id from public.profiles where uid = 1);
      if v_me is null then raise exception '网站助手账号不存在喵'; end if;
    end if;
    insert into public.forum_posts (title, content, image_url, author_id, post_type, is_pinned)
    values (p_title, p_content, coalesce(p_image_url,''), v_me, 'notice', true)
    returning id into v_new_id;
  else
    -- 普通帖：只有站长/管理员能选助手身份，普通用户一律自己
    if p_as_assistant then
      if v_role not in ('owner','admin') then
        raise exception '只有站长/管理员能以助手身份发帖喵';
      end if;
      v_me := (select id from public.profiles where uid = 1);
      if v_me is null then raise exception '网站助手账号不存在喵'; end if;
    end if;
    insert into public.forum_posts (title, content, image_url, author_id, post_type, is_pinned)
    values (p_title, p_content, coalesce(p_image_url,''), v_me, 'post', false)
    returning id into v_new_id;
  end if;

  return v_new_id;
end;
$$;

-- ============================================================
-- 7. 回帖 RPC（分配楼层 + 更新帖子统计）
--    p_parent_id: null=主回帖（分配楼层，从2开始）；非null=楼中楼（不占楼层）
-- ============================================================
create or replace function public.create_forum_reply(
  p_post_id uuid,
  p_content text,
  p_parent_id uuid default null,
  p_image_url text default ''
)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_new_id uuid;
  v_floor integer;
  v_post_exists boolean;
begin
  if v_uid is null then
    raise exception '请先登录喵';
  end if;

  -- 校验发帖人未封禁
  if not exists (select 1 from public.profiles p where p.id = v_uid and p.status = 'active') then
    raise exception '账号异常或被封禁，无法回帖喵';
  end if;

  select exists(select 1 from public.forum_posts where id = p_post_id) into v_post_exists;
  if not v_post_exists then
    raise exception '帖子不存在或已删除喵';
  end if;

  -- 楼中楼：校验父回帖存在且属于同一帖子
  if p_parent_id is not null then
    if not exists (select 1 from public.forum_replies
                   where id = p_parent_id and post_id = p_post_id) then
      raise exception '要回复的楼层不存在喵';
    end if;
    insert into public.forum_replies (post_id, parent_id, author_id, content, image_url)
    values (p_post_id, p_parent_id, v_uid, p_content, coalesce(p_image_url,''))
    returning id into v_new_id;
  else
    -- 主回帖：楼层号 = 该帖当前最大主回帖楼层 + 1（从 2 开始，1 楼留给楼主正文）
    select coalesce(max(floor), 1) + 1 into v_floor
      from public.forum_replies where post_id = p_post_id and parent_id is null;
    insert into public.forum_replies (post_id, parent_id, author_id, content, image_url, floor)
    values (p_post_id, null, v_uid, p_content, coalesce(p_image_url,''), v_floor)
    returning id into v_new_id;
  end if;

  -- 更新帖子统计
  update public.forum_posts
     set reply_count = (select count(*) from public.forum_replies where post_id = p_post_id),
         last_reply_at = now()
   where id = p_post_id;

  return v_new_id;
end;
$$;

-- ============================================================
-- 8. 吧务 RPC：置顶 / 加精（仅站长/管理员）
-- ============================================================
create or replace function public.toggle_forum_pin(p_post_id uuid)
returns boolean
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_new boolean;
begin
  select role into v_role from public.profiles where id = v_uid;
  if v_uid is null or v_role not in ('owner','admin') then
    raise exception '只有站长/管理员能置顶帖子喵';
  end if;
  -- 公告贴永远置顶，不允许取消
  update public.forum_posts
     set is_pinned = case when post_type = 'notice' then true else not is_pinned end
   where id = p_post_id
  returning is_pinned into v_new;
  if v_new is null then raise exception '帖子不存在喵'; end if;
  return v_new;
end;
$$;

create or replace function public.toggle_forum_essence(p_post_id uuid)
returns boolean
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_new boolean;
begin
  select role into v_role from public.profiles where id = v_uid;
  if v_uid is null or v_role not in ('owner','admin') then
    raise exception '只有站长/管理员能加精喵';
  end if;
  update public.forum_posts set is_essence = not is_essence where id = p_post_id
  returning is_essence into v_new;
  if v_new is null then raise exception '帖子不存在喵'; end if;
  return v_new;
end;
$$;

-- ============================================================
-- 9. 删帖 RPC（楼主本人 或 站长/管理员）
-- ============================================================
create or replace function public.delete_forum_post(p_post_id uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_author uuid;
  v_type text;
begin
  select author_id, post_type into v_author, v_type
    from public.forum_posts where id = p_post_id;
  if v_author is null then raise exception '帖子不存在或已删除喵'; end if;
  select role into v_role from public.profiles where id = v_uid;
  if v_uid is null or (v_author <> v_uid and v_role not in ('owner','admin')) then
    raise exception '你没有权限删除这个帖子喵';
  end if;
  delete from public.forum_posts where id = p_post_id;
end;
$$;

-- ============================================================
-- 10. 回帖删除（本人 / 站长管理员 / 楼主可删自己楼内回帖）
--     普通前端不直接调 delete，走 RPC 或 RLS；此处给 RLS 兜底
-- ============================================================
drop policy if exists "auth delete forum_replies" on public.forum_replies;
create policy "auth delete forum_replies" on public.forum_replies
  for delete using (
    auth.uid() = author_id
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('owner','admin'))
    or exists (
      select 1 from public.forum_posts fp
      where fp.id = forum_replies.post_id and fp.author_id = auth.uid()
    )
  );

-- 帖子删除给 RLS 兜底（RPC 主流程已校验）
drop policy if exists "auth delete forum_posts" on public.forum_posts;
create policy "auth delete forum_posts" on public.forum_posts
  for delete using (
    auth.uid() = author_id
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('owner','admin'))
  );
