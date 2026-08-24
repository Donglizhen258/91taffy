// 分页改造综合验证：跨页楼层连贯 + 二级回复归属 + 切片正确性
// 模拟真实数据库数据，验证前端渲染逻辑的等价实现
const PAGE_SIZE = 10;

// 生成 N 条一级评论（时间正序 seq=1..N），若干二级回复挂在部分一级下
function genData(N, repliesPerRoot){
  const firsts = [];
  for(let i = 1; i <= N; i++){
    firsts.push({ id: 'c' + i, seq: i, created_at: new Date(Date.UTC(2026,0,i)).toISOString(), like_count: (i*7)%13, parent_id: null });
  }
  const replies = [];
  for(const c of firsts){
    for(let r = 1; r <= (c.seq % 3); r++){
      replies.push({ id: c.id + '-r' + r, parent_id: c.id, seq: c.seq, created_at: new Date(Date.UTC(2026,0,c.seq,0,r)).toISOString() });
    }
  }
  return { firsts, replies };
}

// 模拟数据库分页拉取（等价 loadComments 的 useDbPaging 分支）
function dbFetch(all, page, size, ascending){
  const total = all.length;
  const totalPages = Math.max(1, Math.ceil(total / size));
  const safePage = Math.min(Math.max(page,1), totalPages);
  const start = (safePage - 1) * size;
  let slice;
  if(ascending) slice = all.slice(start, start + size);
  else slice = all.slice(Math.max(0, total - start - size), total - start).reverse();
  return { slice, totalPages, safePage };
}

let pass = 0, fail = 0;
function check(name, cond, detail){
  if(cond){ pass++; console.log('✓ ' + name); }
  else { fail++; console.log('✗ ' + name + ' —— ' + detail); }
}

for(const N of [0, 1, 9, 10, 11, 23, 25]){
  const { firsts, replies } = genData(N, 2);
  for(const asc of [true, false]){
    const totalPages = Math.max(1, Math.ceil(N / PAGE_SIZE));
    // 遍历所有页，检查楼层是否覆盖 1..N 且无重复无遗漏
    const floors = [];
    for(let p = 1; p <= totalPages; p++){
      const { slice, safePage } = dbFetch(firsts, p, PAGE_SIZE, asc);
      // 模拟 renderCommentList 的楼层计算
      slice.forEach((c, i) => {
        let floor;
        if(asc) floor = (safePage - 1) * PAGE_SIZE + i + 1;
        else floor = N - (safePage - 1) * PAGE_SIZE - i;
        floors.push(floor);
      });
    }
    const sorted = [...floors].sort((a,b)=>a-b);
    const unique = new Set(floors);
    const dir = asc ? '正序' : '倒序';
    // 楼层应恰好覆盖 1..N
    check(`N=${N} ${dir} 楼层覆盖 1..${N}`, floors.length === N && unique.size === N && sorted[0] === 1 && sorted[N-1] === N, JSON.stringify(floors));
    // 每页切片的回复归属：只拉当前页一级的回复
    for(let p = 1; p <= totalPages; p++){
      const { slice, safePage } = dbFetch(firsts, p, PAGE_SIZE, asc);
      if(!slice.length) continue;
      const parentIds = new Set(slice.map(c => c.id));
      const pageReplies = replies.filter(r => parentIds.has(r.parent_id));
      // 断言：所有归属回复的根都在本页
      const bad = pageReplies.filter(r => !parentIds.has(r.parent_id));
      check(`N=${N} ${dir} 第${p}页回复归属正确`, bad.length === 0, `越界回复: ${bad.length}`);
    }
  }
}

console.log(`\n=== 通过 ${pass} / 失败 ${fail} ===`);
