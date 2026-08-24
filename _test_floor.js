// 楼层逻辑验证脚本
// 模拟数据库分页下 时间正序(time_asc) / 倒序(time_desc) 的楼层计算
// 规则：楼层绑定时间正序全局位置
//   time_asc  : 第 i 条 = (页-1)*SIZE + i + 1 楼
//   time_desc : 第 i 条 = TOTAL - (页-1)*SIZE - i 楼（倒序第 i 条 = 正序倒数第 i 条）

function test(total, size, page){
  const totalPages = Math.max(1, Math.ceil(total / size));
  // 生成时间正序的 1..total 条评论
  const comments = Array.from({length: total}, (_, idx) => ({ id: idx+1, seq: idx+1 }));
  const start = (page - 1) * size;

  // 数据库返回：正序取 [start, start+size)
  const ascPage = comments.slice(start, start + size);
  // 数据库返回：倒序取 [total-start-size, total-start)
  const descPage = comments.slice(Math.max(0, total - start - size), total - start).reverse();

  let ok = true;
  const errs = [];
  // 正序楼层
  ascPage.forEach((c, i) => {
    const floor = start + i + 1;
    if(floor !== c.seq){ ok = false; errs.push(`正序第${page}页 第${i}条 floor=${floor} 期望=${c.seq}`); }
  });
  // 倒序楼层（模拟 renderCommentList 的计算：baseFloor = total - (page-1)*size, floor = baseFloor - i）
  const baseFloorDesc = total - start;
  descPage.forEach((c, i) => {
    const floor = baseFloorDesc - i;
    const expectFloor = c.seq;
    if(floor !== expectFloor){ ok = false; errs.push(`倒序第${page}页 第${i}条 floor=${floor} 期望=${expectFloor}`); }
  });
  return { ok, errs, ascPage: ascPage.map(c=>c.seq), descPage: descPage.map(c=>c.seq) };
}

let allOk = true;
const total = 23; // 模拟 23 条一级评论
const size = 10;  // PAGE_SIZE
const pages = Math.max(1, Math.ceil(total / size));
for(let p = 1; p <= pages; p++){
  const r = test(total, size, p);
  if(!r.ok){ allOk = false; console.log(`✗ 第 ${p} 页失败:`); r.errs.forEach(e => console.log('   ', e)); }
  else console.log(`✓ 第 ${p} 页 正序楼层=${r.ascPage.join(',')} | 倒序楼层=${r.descPage.join(',')}`);
}
console.log(allOk ? '\n=== 全部楼层计算正确 ===' : '\n=== 存在错误 ===');
