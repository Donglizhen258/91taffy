// 站内路由端到端流程验证（DOM mock 版）
// 模拟：location.hash + hashchange 事件 + switchView 渲染视图 class
// 验证：用户操作序列下 hash 流转 + 视图切换正确性

// ---- 简易 DOM mock ----
const viewStates = { home:false, forum:false, forumPost:false, profile:false, account:false, admin:false };
const navStates = { home:false, forum:false, account:false, admin:false };
const elements = {};
function makeEl(id){
  return {
    id,
    classes: new Set(),
    classList: {
      add: c => { elements[id].classes.add(c); },
      remove: c => { elements[id].classes.delete(c); },
      toggle: (c, force) => {
        if(force === undefined){ if(elements[id].classes.has(c)) elements[id].classes.delete(c); else elements[id].classes.add(c); }
        else if(force) elements[id].classes.add(c); else elements[id].classes.delete(c);
      },
      contains: c => elements[id].classes.has(c)
    },
    style: {}, textContent: '', innerHTML: '', value: '', disabled: false
  };
}
['viewHome','viewAccount','viewAdmin','viewProfile','viewForum','viewForumPost','navHome','navAccount','navAdmin','navForum','navMenu','profileName'].forEach(id => { elements[id] = makeEl(id); });
const documentMock = {
  getElementById: id => elements[id] || null
};

// ---- 全局 mock ----
let currentHash = '';
const locationMock = {
  get hash(){ return currentHash; },
  set hash(v){
    if(v === currentHash) return;
    currentHash = v;
    // 同步触发 hashchange，消除测试时序不确定性
    if(handlers.length) handlers.forEach(h => h());
  }
};
let handlers = [];
const windowMock = {
  addEventListener: (ev, fn) => { if(ev === 'hashchange') handlers.push(fn); },
  location: locationMock
};

// ---- 复刻 index.html 的路由核心（不含 DOM 依赖部分） ----
let lastRouteKey = '';
let routerPending = false;
let pendingRouteKey = null;
let currentForumPost = null;
let viewingUserId = null;

function parseHash(){
  const h = (currentHash || '').replace(/^#\/?/, '');
  if(!h) return { name: 'home', param: null };
  const parts = h.split('/');
  const name = parts[0];
  if(name === 'forum' && parts[1] === 'post') return { name: 'forumPost', param: parts[2] || null };
  if(name === 'profile') return { name: 'profile', param: parts[1] || null };
  if(['home','forum','account','admin'].includes(name)) return { name, param: null };
  return { name: 'home', param: null };
}
function goRoute(path){
  const target = '#' + (path.startsWith('/') ? path : '/' + path);
  if(currentHash === target) { handleRoute(); return; }
  locationMock.hash = target;
}
function routeKey(){
  const { name, param } = parseHash();
  return name + (param ? '|' + param : '');
}
function switchView(name){
  ['home','account','admin','profile','forum','forumPost'].forEach(v => {
    const el = elements['view' + v.charAt(0).toUpperCase() + v.slice(1)];
    if(el) el.classList.remove('show');
  });
  const map = { home:'viewHome', account:'viewAccount', admin:'viewAdmin', profile:'viewProfile', forum:'viewForum', forumPost:'viewForumPost' };
  const el = elements[map[name]];
  if(el) el.classList.add('show');
}
async function handleRoute(){
  const key = routeKey();
  if(key === lastRouteKey && !routerPending) return;
  if(routerPending){ pendingRouteKey = key; return; }
  routerPending = true;
  pendingRouteKey = null;
  try{
    const { name, param } = parseHash();
    if(name === 'forumPost'){
      if(currentForumPost && String(currentForumPost.id) === String(param)){
        switchView('forumPost');
      } else if(param){
        currentForumPost = { id: param, title: '帖子' + param };
        switchView('forumPost');
      } else {
        switchView('forum');
      }
    } else if(name === 'profile'){
      if(param){
        viewingUserId = param;
        switchView('profile');
      } else {
        switchView('home');
      }
    } else if(name === 'account'){
      switchView('account');
    } else if(name === 'admin'){
      switchView('admin');
    } else if(name === 'forum'){
      switchView('forum');
    } else {
      switchView('home');
    }
    lastRouteKey = key;
  }catch(e){
    switchView('home');
    lastRouteKey = key;
  }finally{
    routerPending = false;
    if(pendingRouteKey && pendingRouteKey !== key){
      setTimeout(() => handleRoute(), 0);
    }
    pendingRouteKey = null;
  }
}
windowMock.addEventListener('hashchange', handleRoute);

// ---- 测试辅助 ----
let pass = 0, fail = 0;
function check(name, cond, detail){
  if(cond){ pass++; console.log('✓ ' + name); }
  else { fail++; console.log('✗ ' + name + ' —— ' + detail); }
}
function viewShown(name){
  const map = { home:'viewHome', account:'viewAccount', admin:'viewAdmin', profile:'viewProfile', forum:'viewForum', forumPost:'viewForumPost' };
  return elements[map[name]].classes.has('show');
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function main(){
  // 场景1：初始化（无 hash）→ 首页
  await handleRoute();
  check('初始化无 hash → 显示首页', viewShown('home'));

  // 场景2：点击论坛导航（直接改 hash + 手动触发，等价浏览器 hashchange）
  currentHash = '#/forum'; handlers.forEach(h => h());
  await sleep(20);
  check('goRoute(forum) → hash=#/forum', currentHash === '#/forum');
  check('显示论坛视图', viewShown('forum'));

  // 场景3：点击帖子（模拟 openForumPost 非静默）
  currentHash = '#/forum/post/123'; handlers.forEach(h => h());
  await sleep(20);
  check('进帖子 → hash=#/forum/post/123', currentHash === '#/forum/post/123');
  check('显示帖子详情', viewShown('forumPost'));

  // 场景4：后退 → 论坛（直接改 hash 需手动触发，因为不经过 setter 同步调用）
  currentHash = '#/forum'; handlers.forEach(h => h());
  await sleep(20);
  check('后退 → hash=#/forum', currentHash === '#/forum');
  check('显示论坛视图', viewShown('forum'));

  // 场景5：再后退 → 首页
  currentHash = ''; handlers.forEach(h => h());
  await sleep(20);
  check('再后退 → 空 hash 显示首页', viewShown('home'));

  // 场景6：直接访问深链接（刷新帖子页）
  currentHash = '#/forum/post/999'; handlers.forEach(h => h());
  await sleep(20);
  check('直接访问 #/forum/post/999 → 显示帖子详情', viewShown('forumPost'));
  check('帖子数据自动补拉 (currentForumPost.id=999)', currentForumPost && currentForumPost.id === '999');

  // 场景7：资料页 → 后退
  currentHash = '#/profile/abc'; handlers.forEach(h => h());
  await sleep(20);
  check('进资料页 → hash=#/profile/abc 显示资料视图', currentHash === '#/profile/abc' && viewShown('profile'));
  currentHash = '#/home'; handlers.forEach(h => h());
  await sleep(20);
  check('资料页后退 → 显示首页', viewShown('home'));

  console.log(`\n=== 通过 ${pass} / 失败 ${fail} ===`);
}
main();
