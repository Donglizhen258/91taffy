-- 91taffy.com 塔菲论坛：公告属性独立切换（2026-08-23）
-- 背景：三属性独立化时漏掉了公告本身的取消能力——公告贴 post_type=notice 一旦设置就改不回普通帖。
-- 本迁移新增 toggle_forum_notice RPC：站长/管理员可在「公告贴 ↔ 普通帖」间独立切换，
--      公告=首页横幅；置顶/精华是独立属性，不受切换影响。
-- 运行方式：Supabase 控制台 -> SQL Editor 或 psycopg2 直连执行。幂等可重复执行。

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
  -- 公告 ↔ 普通帖 独立切换；不触碰 is_pinned / is_essence
  if v_type = 'notice' then
    update public.forum_posts set post_type = 'post' where id = p_post_id returning post_type into v_new;
  else
    update public.forum_posts set post_type = 'notice' where id = p_post_id returning post_type into v_new;
  end if;
  return v_new;
end;
$$;
