-- 91taffy.com 塔菲论坛：楼层号永不回退（2026-08-24）
-- 背景：create_forum_reply 原先用 `coalesce(max(floor),1)+1` 取现存回帖最大楼层分配新楼层号。
--       一旦删掉最高楼，max 变小，下一条新回帖会复用被删的楼层号（跳号/继承旧号）。
--       比如 2/3/4/5 楼，删掉 5 楼后，新回帖又拿到 5 楼。
-- 方案：给 forum_posts 加 reply_seq 楼层计数器（永不回退），主回帖用 reply_seq+1 分配楼层号。
--       删除主回帖不回退计数器，保证楼层号严格递增、永不重复。
-- 运行方式：psycopg2 直连生产库执行，幂等可重复执行。

-- ============================================================
-- 1. forum_posts 增加楼层计数器 reply_seq（默认 1，主回帖从 2 开始递增分配）
-- ============================================================
alter table public.forum_posts
  add column if not exists reply_seq integer not null default 1;

comment on column public.forum_posts.reply_seq is '楼层计数器：主回帖楼层号从此递增分配，永不回退（删除最高楼也不回退）';

-- ============================================================
-- 2. 回填历史数据：已有帖子把 reply_seq 设为当前最大主回帖楼层（保持历史楼层不变）
-- ============================================================
update public.forum_posts fp
   set reply_seq = coalesce((
       select max(r.floor) from public.forum_replies r
        where r.post_id = fp.id and r.parent_id is null
   ), 1)
 where fp.reply_seq = 1
   and exists (select 1 from public.forum_replies r
               where r.post_id = fp.id and r.parent_id is null and r.floor > 1);

-- ============================================================
-- 3. create_forum_reply 改为用 reply_seq 分配楼层号（永不回退）
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
    -- 主回帖：楼层号 = 帖子楼层计数器 + 1（原子自增，永不回退；1 楼留给楼主正文）
    update public.forum_posts
       set reply_seq = reply_seq + 1
     where id = p_post_id
     returning reply_seq into v_floor;
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
