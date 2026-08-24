-- 91taffy.com 塔菲论坛抽奖：发布人可修改截止时间（2026-08-24）
-- 需求：抽奖发布人（楼主/站长/管理员）在抽奖进行中可修改截止时间。
--      即时模式：可改到新时间，也可取消（p_deadline=null，即不限时）；
--      定时模式：可改到新时间（必须晚于当前时间）。
-- 运行方式：psycopg2 直连生产库执行。幂等可重复执行。

create or replace function public.update_lottery_deadline(
  p_post_id uuid,
  p_deadline timestamptz
)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_post_author uuid;
  v_lt_exists boolean;
  v_status text;
  v_draw_mode text;
begin
  if v_uid is null then
    raise exception '请先登录喵';
  end if;
  select exists(select 1 from public.forum_lotteries where post_id = p_post_id) into v_lt_exists;
  if not v_lt_exists then
    raise exception '这不是一个抽奖帖喵';
  end if;
  select role into v_role from public.profiles where id = v_uid;
  select author_id into v_post_author from public.forum_posts where id = p_post_id;
  -- 仅站长(owner) 或 发帖人(楼主) 可改，管理员 admin 也不得改动（防徇私舞弊）
  if v_role <> 'owner' and (v_post_author is null or v_post_author <> v_uid) then
    raise exception '只有发起人或站长能修改截止时间喵';
  end if;
  select status, draw_mode into v_status, v_draw_mode
    from public.forum_lotteries where post_id = p_post_id;
  if v_status <> 'drawing' then
    raise exception '该抽奖已结束，无法修改截止时间喵';
  end if;
  -- 定时模式：截止时间必须晚于当前时间（不能改成过去，否则会立即触发开奖）
  if v_draw_mode = 'scheduled' then
    if p_deadline is null then
      raise exception '定时开奖必须有截止时间喵';
    end if;
    if p_deadline <= now() then
      raise exception '定时开奖的截止时间必须晚于当前时间喵';
    end if;
  else
    -- 即时模式：可选截止时间（null=不限时）；给了时间则必须晚于当前
    if p_deadline is not null and p_deadline <= now() then
      raise exception '截止时间必须晚于当前时间喵';
    end if;
  end if;

  update public.forum_lotteries
     set deadline = p_deadline
   where post_id = p_post_id;
end;
$$;

grant execute on function public.update_lottery_deadline(uuid, timestamptz) to authenticated;
