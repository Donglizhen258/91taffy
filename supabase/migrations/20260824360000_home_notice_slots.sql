-- 91taffy.com 塔菲论坛：首页公告三栏位 + 可调整（2026-08-24）
-- 需求：首页公告从单横幅改为 3 个栏位；站长/管理员可调整每个栏位展示的公告帖。
-- 方案：forum_posts 加 notice_slot 列（1/2/3，null=不占首页栏位，仅公告帖可用）。
--       新增 RPC set_notice_slot(post_id, slot)：仅站长/管理员，把某公告帖设到栏位 1/2/3，
--       传 null 移除；设置时自动清掉其他帖子对该栏位的占用（一栏一帖）。
-- 运行方式：psycopg2 直连生产库执行。幂等可重复执行。

-- ============================================================
-- 1. forum_posts 加公告栏位列
-- ============================================================
alter table public.forum_posts
  add column if not exists notice_slot smallint check (notice_slot in (1,2,3));

comment on column public.forum_posts.notice_slot is '首页公告栏位 1/2/3，null=不占栏位（仅公告帖可用）';

create index if not exists idx_forum_posts_notice_slot
  on public.forum_posts (notice_slot) where notice_slot is not null;

-- ============================================================
-- 2. 设置公告栏位 RPC（仅站长/管理员）
--    p_slot: 1/2/3 设置栏位；null 移除栏位（帖子仍保留公告属性，只是不再占首页栏位）
-- ============================================================
create or replace function public.set_notice_slot(p_post_id uuid, p_slot smallint)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_post_type text;
begin
  if v_uid is null then
    raise exception '请先登录喵';
  end if;
  if p_slot is not null and p_slot not in (1,2,3) then
    raise exception '栏位只能是 1/2/3 喵';
  end if;
  select role into v_role from public.profiles where id = v_uid;
  if v_role is null or v_role not in ('owner','admin') then
    raise exception '只有站长/管理员能调整公告栏位喵';
  end if;
  select post_type into v_post_type from public.forum_posts where id = p_post_id;
  if v_post_type is null then
    raise exception '帖子不存在或已删除喵';
  end if;
  if v_post_type <> 'notice' then
    raise exception '只有公告贴能设置首页栏位，请先设为公告喵';
  end if;

  if p_slot is not null then
    -- 清掉其他帖子对该栏位的占用（一栏一帖）
    update public.forum_posts
       set notice_slot = null
     where notice_slot = p_slot and id <> p_post_id;
  end if;

  update public.forum_posts
     set notice_slot = p_slot
   where id = p_post_id;
end;
$$;

grant execute on function public.set_notice_slot(uuid, smallint) to authenticated;

-- ============================================================
-- 3. 取消公告时清空栏位（改 toggle_forum_notice：切回普通帖时同时清 notice_slot）
-- ============================================================
create or replace function public.toggle_forum_notice(p_post_id uuid)
returns text
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_type text;
  v_new text;
begin
  select role into v_role from public.profiles where id = v_uid;
  if v_uid is null or v_role not in ('owner','admin') then
    raise exception '只有站长/管理员能设置/取消公告喵';
  end if;
  select post_type into v_type from public.forum_posts where id = p_post_id;
  if v_type is null then raise exception '帖子不存在喵'; end if;
  if v_type = 'notice' then
    update public.forum_posts
       set post_type = 'post', notice_slot = null
     where id = p_post_id
     returning post_type into v_new;
  else
    update public.forum_posts set post_type = 'notice' where id = p_post_id returning post_type into v_new;
  end if;
  return v_new;
end;
$$;
