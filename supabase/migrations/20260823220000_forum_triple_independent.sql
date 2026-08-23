-- 91taffy.com 塔菲论坛：公告/精华/置顶 三属性独立化（2026-08-23）
-- 背景：公告贴此前强制置顶且不能取消。现改为三属性完全独立——
--      公告贴=首页横幅；精华贴=精华合集；置顶贴=论坛置顶。三者互不影响，均可独立设置/取消。
-- 运行方式：Supabase 控制台 -> SQL Editor 或 psycopg2 直连执行。幂等可重复执行。

-- ============================================================
-- 1. 发帖 RPC：公告贴不再强制置顶（is_pinned 默认 false）
--    公告/普通帖的置顶由站长/管理员事后用置顶按钮独立控制
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

  -- 公告贴：仅站长/管理员可发；不强制置顶（置顶是独立的）
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
    values (p_title, p_content, coalesce(p_image_url,''), v_me, 'notice', false)
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
-- 2. 置顶切换 RPC：公告贴也可独立置顶/取消置顶（不再强制置顶）
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
  -- 三属性独立：任何帖子（含公告）都允许切换置顶状态
  update public.forum_posts
     set is_pinned = not is_pinned
   where id = p_post_id
  returning is_pinned into v_new;
  if v_new is null then raise exception '帖子不存在喵'; end if;
  return v_new;
end;
$$;
