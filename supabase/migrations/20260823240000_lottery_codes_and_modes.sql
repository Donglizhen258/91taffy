-- 91taffy.com 塔菲论坛抽奖升级：兑换码 + 两种抽奖模式（2026-08-23）
-- 需求：
--   1. 虚拟奖品支持兑换码：每个虚拟奖品可配多个兑换码（数量=中奖名额），中奖者领取后能看到兑换码复制去兑换
--   2. 即时开奖模式：发起人限定可抽奖人数 N，参与者一抽即出是否中奖结果（抽中即中奖，先到先得）
--   3. 定时开奖模式：指定截止时间，到点自动对所有参与者开奖（保留原手动开奖）
-- 表结构变更：
--   forum_lotteries        + draw_mode(instant/scheduled) + max_entries(即时限量) + entry_count(已参与人数)
--   forum_lottery_winners  + code(已分配兑换码)
--   prizes JSONB 新结构:   [{name,type,count,codes:["xxx","yyy"]}]  (虚拟奖品可带 codes)
-- 运行方式：Supabase 控制台 SQL Editor 或 psycopg2 直连执行。幂等可重复执行。

-- ============================================================
-- 1. 表结构扩展
-- ============================================================
alter table public.forum_lotteries
  add column if not exists draw_mode text not null default 'scheduled'
    check (draw_mode in ('instant','scheduled'));
alter table public.forum_lotteries
  add column if not exists max_entries integer;
alter table public.forum_lotteries
  add column if not exists entry_count integer not null default 0;

alter table public.forum_lottery_winners
  add column if not exists code text default '';

comment on column public.forum_lotteries.draw_mode is '抽奖模式: instant=即时开奖(限人数一抽即中) / scheduled=定时开奖(到点统一开)';
comment on column public.forum_lotteries.max_entries is '即时模式限定可抽奖人数上限';
comment on column public.forum_lotteries.entry_count is '已参与/已抽奖人数';
comment on column public.forum_lottery_winners.code is '虚拟奖品分配的兑换码';

-- ============================================================
-- 2. 开奖核心逻辑（内部函数，仅服务端调用，不暴露给 RPC）
--    逐奖项随机抽取，中奖者不重复；虚拟奖品自动分配兑换码
-- ============================================================
create or replace function public._lottery_draw_core(p_post_id uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_lottery record;
  v_entrants uuid[];
  v_already_won uuid[] := '{}';
  v_prize record;
  v_prize_codes jsonb;
  v_i integer;
  v_idx integer;
  v_pick uuid;
  v_code text;
  v_total_winners integer := 0;
begin
  select * into v_lottery from public.forum_lotteries where post_id = p_post_id;
  if v_lottery.post_id is null then
    raise exception '这不是一个抽奖帖喵';
  end if;
  if v_lottery.status <> 'drawing' then
    raise exception '该抽奖已开奖或已结束喵';
  end if;

  -- 收集参与者（随机序）
  select array_agg(user_id order by random())
    into v_entrants
    from public.forum_lottery_entries
    where post_id = p_post_id;
  if v_entrants is null or cardinality(v_entrants) = 0 then
    update public.forum_lotteries
       set status = 'drawn', winner_count = 0
     where post_id = p_post_id;
    return;
  end if;

  -- 逐奖项抽取（含数组下标，用于取兑换码）
  for v_prize in select * from jsonb_array_elements(v_lottery.prizes) with ordinality as p(v, idx)
    where (p.v->>'count')::int >= 1
  loop
    v_i := 0;
    v_prize_codes := coalesce(v_prize.v->'codes', '[]'::jsonb);
    while v_i < (v_prize.v->>'count')::int loop
      exit when cardinality(v_entrants) = 0;
      v_idx := 1 + floor(random() * cardinality(v_entrants))::int;
      v_pick := v_entrants[v_idx];
      v_entrants := v_entrants[1:v_idx-1] || v_entrants[v_idx+1:cardinality(v_entrants)];
      -- 虚拟奖品：按已中人数顺序分配兑换码
      v_code := '';
      if v_prize.v->>'type' = 'virtual' and jsonb_array_length(v_prize_codes) > v_i then
        v_code := v_prize_codes->v_i ->> 0;
      end if;
      insert into public.forum_lottery_winners (post_id, user_id, prize_name, prize_type, code)
      values (p_post_id, v_pick, v_prize.v->>'name', v_prize.v->>'type', v_code);
      v_total_winners := v_total_winners + 1;
      v_i := v_i + 1;
    end loop;
  end loop;

  update public.forum_lotteries
     set status = 'drawn', winner_count = v_total_winners
   where post_id = p_post_id;
end;
$$;

-- 内部函数不暴露给 anon/authenticated（只能被服务端函数调用）
revoke execute on function public._lottery_draw_core(uuid) from anon, authenticated;

-- ============================================================
-- 3. 定时开奖 RPC（站长/管理员/楼主手动开奖）
-- ============================================================
create or replace function public.draw_lottery(p_post_id uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_lottery_exists boolean;
  v_post_author uuid;
begin
  if v_uid is null then
    raise exception '请先登录喵';
  end if;
  select role into v_role from public.profiles where id = v_uid;
  select exists(select 1 from public.forum_lotteries where post_id = p_post_id) into v_lottery_exists;
  if not v_lottery_exists then
    raise exception '这不是一个抽奖帖喵';
  end if;
  select author_id into v_post_author from public.forum_posts where id = p_post_id;
  if v_role not in ('owner','admin') and (v_post_author is null or v_post_author <> v_uid) then
    raise exception '只有发起人或站长/管理员能开奖喵';
  end if;
  perform public._lottery_draw_core(p_post_id);
end;
$$;

-- ============================================================
-- 4. 到点自动开奖 RPC（定时模式：截止时间已过，任何登录用户可触发，只执行一次）
-- ============================================================
create or replace function public.maybe_auto_draw(p_post_id uuid)
returns boolean
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_lottery record;
begin
  if v_uid is null then
    raise exception '请先登录喵';
  end if;
  select * into v_lottery from public.forum_lotteries where post_id = p_post_id;
  if v_lottery.post_id is null then
    return false;
  end if;
  -- 仅定时模式、进行中、截止时间已过才自动开奖
  if v_lottery.draw_mode <> 'scheduled'
     or v_lottery.status <> 'drawing'
     or v_lottery.deadline is null
     or v_lottery.deadline >= now() then
    return false;
  end if;
  perform public._lottery_draw_core(p_post_id);
  return true;
end;
$$;

-- ============================================================
-- 5. 即时开奖 RPC（一抽即出结果，先到先得，限量 max_entries）
--    返回 jsonb: {won:bool, prize_name, prize_type, code, entry_count, max_entries, finished}
-- ============================================================
create or replace function public.draw_lottery_instant(p_post_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_lottery record;
  v_total_prizes integer := 0;
  v_won_count integer := 0;
  v_remaining_prizes integer;
  v_chances_left integer;
  v_entered_after integer;
  v_won boolean := false;
  v_prize_name text := '';
  v_prize_type text := '';
  v_code text := '';
  v_finished boolean := false;
  v_candidates jsonb := '[]';
  v_pick jsonb;
  v_candidate jsonb;
  v_prize_codes jsonb;
  v_alloc_idx integer;
  v_this_prize_won integer;
begin
  if v_uid is null then
    raise exception '请先登录喵';
  end if;
  if not exists (select 1 from public.profiles p where p.id = v_uid and p.status = 'active') then
    raise exception '账号异常或被封禁，无法参与抽奖喵';
  end if;
  select * into v_lottery from public.forum_lotteries where post_id = p_post_id;
  if v_lottery.post_id is null then
    raise exception '这不是一个抽奖帖喵';
  end if;
  if v_lottery.draw_mode <> 'instant' then
    raise exception '该抽奖不是即时开奖模式喵';
  end if;
  if v_lottery.status <> 'drawing' then
    raise exception '该抽奖已结束喵';
  end if;
  if exists (select 1 from public.forum_lottery_entries where post_id = p_post_id and user_id = v_uid)
     or exists (select 1 from public.forum_lottery_winners where post_id = p_post_id and user_id = v_uid) then
    raise exception '你已经参与过这个抽奖啦喵';
  end if;
  if v_lottery.entry_count >= v_lottery.max_entries then
    raise exception '该抽奖名额已抽完喵';
  end if;

  -- 占用一个参与名额（写入参与记录，保持数据一致）
  insert into public.forum_lottery_entries (post_id, user_id)
  values (p_post_id, v_uid);
  update public.forum_lotteries
     set entry_count = entry_count + 1
   where post_id = p_post_id
  returning entry_count into v_entered_after;

  -- 统计：奖品总名额 & 已中奖人数
  select coalesce(sum((p->>'count')::int), 0)
    into v_total_prizes
    from jsonb_array_elements(v_lottery.prizes) as p
    where (p->>'count')::int >= 1;
  select count(*) into v_won_count
    from public.forum_lottery_winners where post_id = p_post_id;
  v_remaining_prizes := v_total_prizes - v_won_count;

  -- 本次抽奖后剩余可抽次数
  v_chances_left := v_lottery.max_entries - v_entered_after;

  -- 中奖判定：保证名额最终抽完（剩余名额>=剩余次数则必中）
  if v_remaining_prizes > 0 then
    if v_chances_left <= 0 or v_remaining_prizes >= v_chances_left then
      v_won := true;
    else
      v_won := (random() < v_remaining_prizes::float / v_chances_left::float);
    end if;
  end if;

  -- 抽中：从还有名额的奖品中随机选一个，分配兑换码
  if v_won then
    select coalesce(jsonb_agg(p), '[]'::jsonb)
      into v_candidates
      from jsonb_array_elements(v_lottery.prizes) as p
      where (p->>'count')::int >= 1
        and (p->>'type') in ('virtual','physical')
        and (select count(*) from public.forum_lottery_winners w
             where w.post_id = p_post_id and w.prize_name = p->>'name') < (p->>'count')::int;
    if jsonb_array_length(v_candidates) > 0 then
      v_pick := v_candidates->floor(random() * jsonb_array_length(v_candidates))::int;
      v_prize_name := v_pick->>'name';
      v_prize_type := v_pick->>'type';
      -- 虚拟奖品：按该奖品已中人数顺序分配兑换码
      if v_prize_type = 'virtual' then
        v_prize_codes := coalesce(v_pick->'codes', '[]'::jsonb);
        select count(*) into v_this_prize_won
          from public.forum_lottery_winners
          where post_id = p_post_id and prize_name = v_prize_name;
        if jsonb_array_length(v_prize_codes) > v_this_prize_won then
          v_code := v_prize_codes->v_this_prize_won ->> 0;
        end if;
      end if;
      insert into public.forum_lottery_winners (post_id, user_id, prize_name, prize_type, code)
      values (p_post_id, v_uid, v_prize_name, v_prize_type, v_code);
    end if;
  end if;

  -- 参与数是否已抽满 -> 结束
  v_finished := (v_entered_after >= v_lottery.max_entries);
  if v_finished then
    update public.forum_lotteries
       set status = 'drawn', winner_count = (select count(*) from public.forum_lottery_winners where post_id = p_post_id)
     where post_id = p_post_id;
  end if;

  return jsonb_build_object(
    'won', v_won,
    'prize_name', v_prize_name,
    'prize_type', v_prize_type,
    'code', v_code,
    'entry_count', v_entered_after,
    'max_entries', v_lottery.max_entries,
    'finished', v_finished
  );
end;
$$;

-- ============================================================
-- 6. 发起抽奖 RPC 扩展（新增 draw_mode / max_entries；prizes 支持 codes）
-- ============================================================
create or replace function public.create_lottery_post(
  p_title text,
  p_content text,
  p_prizes jsonb,
  p_image_url text default '',
  p_claim_note text default '',
  p_as_assistant boolean default false,
  p_draw_mode text default 'scheduled',
  p_max_entries integer default null,
  p_deadline timestamptz default null
)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_me uuid;
  v_role text;
  v_post_id uuid;
  v_bad integer;
  v_type text;
begin
  if v_uid is null then
    raise exception '请先登录喵';
  end if;
  select id, role into v_me, v_role from public.profiles where id = v_uid;
  if v_me is null or v_role not in ('owner','admin') then
    raise exception '只有站长/管理员能发起抽奖喵';
  end if;
  if p_draw_mode not in ('instant','scheduled') then
    raise exception '抽奖模式不合法喵';
  end if;
  if p_draw_mode = 'instant' and (p_max_entries is null or p_max_entries < 1) then
    raise exception '即时开奖模式需要设置可抽奖人数（至少1人）喵';
  end if;
  if p_draw_mode = 'scheduled' and p_max_entries is not null then
    raise exception '定时开奖模式不需要限定人数喵';
  end if;
  if p_prizes is null or jsonb_array_length(p_prizes) = 0 then
    raise exception '至少要有一个奖品喵';
  end if;

  -- 校验奖品：name/type/count；虚拟奖品若带 codes 则数量必须 >= count
  select count(*) into v_bad from jsonb_array_elements(p_prizes) as p
    where p->>'name' is null or p->>'name' = ''
       or p->>'type' not in ('virtual','physical')
       or coalesce((p->>'count')::int, 0) < 1;
  if v_bad > 0 then
    raise exception '奖品配置有误：需包含名称、类型(virtual/physical)、数量喵';
  end if;
  for v_type in select distinct p->>'type' from jsonb_array_elements(p_prizes) as p
    where p->>'type' = 'virtual' and p->'codes' is not null
  loop
    if exists (select 1 from jsonb_array_elements(p_prizes) as p
               where p->>'type' = 'virtual'
                 and p->'codes' is not null
                 and jsonb_array_length(p->'codes') < (p->>'count')::int) then
      raise exception '虚拟奖品的兑换码数量不能少于中奖名额喵';
    end if;
  end loop;

  -- 可选以助手身份署名
  if p_as_assistant then
    v_me := (select id from public.profiles where uid = 1);
    if v_me is null then raise exception '网站助手账号不存在喵'; end if;
  end if;

  insert into public.forum_posts (title, content, image_url, author_id, post_type, is_pinned)
  values (p_title, p_content, coalesce(p_image_url,''), v_me, 'post', false)
  returning id into v_post_id;

  insert into public.forum_lotteries (post_id, prizes, deadline, claim_note, created_by, draw_mode, max_entries, entry_count)
  values (v_post_id, p_prizes, p_deadline, coalesce(p_claim_note,''), v_me, p_draw_mode,
          case when p_draw_mode='instant' then p_max_entries else null end, 0);

  return v_post_id;
end;
$$;

-- ============================================================
-- 7. 参与抽奖 RPC：即时模式禁止使用（即时模式用 draw_lottery_instant）
-- ============================================================
create or replace function public.enter_lottery(p_post_id uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_status text;
  v_deadline timestamptz;
  v_draw_mode text;
  v_lottery_exists boolean;
begin
  if v_uid is null then
    raise exception '请先登录喵';
  end if;
  if not exists (select 1 from public.profiles p where p.id = v_uid and p.status = 'active') then
    raise exception '账号异常或被封禁，无法参与抽奖喵';
  end if;
  select exists(select 1 from public.forum_lotteries where post_id = p_post_id)
    into v_lottery_exists;
  if not v_lottery_exists then
    raise exception '这不是一个抽奖帖喵';
  end if;
  select status, deadline, draw_mode into v_status, v_deadline, v_draw_mode
    from public.forum_lotteries where post_id = p_post_id;
  if v_draw_mode = 'instant' then
    raise exception '这是即时开奖抽奖，请直接点「立即抽」喵';
  end if;
  if v_status <> 'drawing' then
    raise exception '该抽奖已开奖或已结束，无法参与喵';
  end if;
  if v_deadline is not null and v_deadline < now() then
    raise exception '该抽奖已截止参与喵';
  end if;
  if exists (select 1 from public.forum_lottery_entries where post_id = p_post_id and user_id = v_uid) then
    raise exception '你已经参与过这个抽奖啦喵';
  end if;
  insert into public.forum_lottery_entries (post_id, user_id) values (p_post_id, v_uid);
end;
$$;
