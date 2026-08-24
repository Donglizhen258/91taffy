-- 91taffy.com 塔菲论坛抽奖：奖品分配明细（发起人可见，支持回收）（2026-08-24）
-- 需求：抽奖发起人（楼主/站长/管理员）要能看到每个奖品的抽取进度——
--       哪些名额已被抽走、还剩几个，虚拟奖品哪些兑换码已分配、哪些未分配，
--       方便对没抽完的虚拟奖品（未分配的兑换码）做回收。
-- 改动：新增 RPC get_lottery_prize_status(post_id)：
--       返回 jsonb 数组，每个奖品包含 name/type/count/won_count/remaining，
--       虚拟奖品额外含 assigned_codes(已分配兑换码) / unassigned_codes(未分配兑换码，可回收)。
--       仅 楼主/站长/管理员 可调用。
-- 运行方式：psycopg2 直连生产库执行。幂等可重复执行。

create or replace function public.get_lottery_prize_status(p_post_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_post_author uuid;
  v_is_manager boolean := false;
  v_lt_exists boolean;
  v_prizes jsonb;
  v_prize jsonb;
  v_result jsonb := '[]'::jsonb;
  v_name text;
  v_type text;
  v_count integer;
  v_codes jsonb;
  v_won_count integer;
  v_assigned jsonb := '[]'::jsonb;
  v_assigned_set text[];
  v_unassigned jsonb := '[]'::jsonb;
  v_item jsonb;
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
  v_is_manager := (v_role in ('owner','admin')) or (v_post_author is not null and v_post_author = v_uid);

  if not v_is_manager then
    raise exception '只有发起人或站长/管理员能查看奖品分配明细喵';
  end if;

  select prizes into v_prizes from public.forum_lotteries where post_id = p_post_id;

  for v_prize in select * from jsonb_array_elements(coalesce(v_prizes, '[]'::jsonb))
  loop
    v_name := v_prize->>'name';
    v_type := v_prize->>'type';
    v_count := coalesce((v_prize->>'count')::int, 0);
    if v_name is null or v_name = '' or v_count < 1 then
      continue;
    end if;

    -- 该奖品已中奖人数
    select count(*) into v_won_count
      from public.forum_lottery_winners
      where post_id = p_post_id and prize_name = v_name;

    v_item := jsonb_build_object(
      'name', v_name,
      'type', v_type,
      'count', v_count,
      'won_count', v_won_count,
      'remaining', greatest(v_count - v_won_count, 0)
    );

    -- 虚拟奖品：拆分已分配 / 未分配兑换码
    if v_type = 'virtual' then
      v_codes := coalesce(v_prize->'codes', '[]'::jsonb);
      -- 已分配：winners 里该奖品 code 非空的记录，按中奖顺序
      select coalesce(array_agg(w.code order by w.claimed_at nulls last, w.user_id), '{}')
        into v_assigned_set
        from public.forum_lottery_winners w
        where w.post_id = p_post_id and w.prize_name = v_name
          and w.code is not null and w.code <> '';
      v_assigned := coalesce(to_jsonb(v_assigned_set), '[]'::jsonb);
      -- 未分配：codes 里剔除已分配的
      select coalesce(jsonb_agg(c), '[]'::jsonb)
        into v_unassigned
        from jsonb_array_elements_text(v_codes) as c
        where c <> all(coalesce(v_assigned_set, '{}'::text[]));
      v_item := v_item
        || jsonb_build_object(
          'assigned_codes', v_assigned,
          'unassigned_codes', v_unassigned
        );
    end if;

    v_result := v_result || jsonb_build_array(v_item);
  end loop;

  return v_result;
end;
$$;

grant execute on function public.get_lottery_prize_status(uuid) to authenticated;
