// 站内路由逻辑验证：parseHash / goRoute 目标 hash / 关键场景流转
// 纯逻辑模拟，不依赖浏览器 DOM

// 复刻 parseHash（从 index.html 提取）
function parseHash(hash){
  const h = (hash || '').replace(/^#\/?/, '');
  if(!h) return { name: 'home', param: null };
  const parts = h.split('/');
  const name = parts[0];
  if(name === 'forum' && parts[1] === 'post') return { name: 'forumPost', param: parts[2] || null };
  if(name === 'profile') return { name: 'profile', param: parts[1] || null };
  if(['home','forum','account','admin'].includes(name)) return { name, param: null };
  return { name: 'home', param: null };
}

// 复刻 goRoute 的目标 hash 生成
function goRouteTarget(path){
  return '#' + (path.startsWith('/') ? path : '/' + path);
}

let pass = 0, fail = 0;
function check(name, cond, detail){
  if(cond){ pass++; console.log('✓ ' + name); }
  else { fail++; console.log('✗ ' + name + ' —— ' + detail); }
}

// parseHash 测试
check('空 hash → home', parseHash('').name === 'home');
check('#/home → home', parseHash('#/home').name === 'home');
check('#/forum → forum', parseHash('#/forum').name === 'forum');
check('#/forum/post/123 → forumPost/123',
  parseHash('#/forum/post/123').name === 'forumPost' && parseHash('#/forum/post/123').param === '123');
check('#/profile/abc → profile/abc',
  parseHash('#/profile/abc').name === 'profile' && parseHash('#/profile/abc').param === 'abc');
check('#/account → account', parseHash('#/account').name === 'account');
check('#/admin → admin', parseHash('#/admin').name === 'admin');
check('未知 hash → home', parseHash('#/weird').name === 'home');
check('#/forum/foo（无 post）→ forum', parseHash('#/forum/foo').name === 'forum');
check('#/profile（无参数）→ profile/null', parseHash('#/profile').name === 'profile' && parseHash('#/profile').param === null);

// goRoute 目标 hash 测试
check('goRoute(forum) → #/forum', goRouteTarget('forum') === '#/forum');
check('goRoute(/forum) → #/forum', goRouteTarget('/forum') === '#/forum');
check('goRoute(forum/post/123) → #/forum/post/123', goRouteTarget('forum/post/123') === '#/forum/post/123');
check('goRoute(profile/abc) → #/profile/abc', goRouteTarget('profile/abc') === '#/profile/abc');

// 关键场景：层级流转（模拟 hash 变化序列）
// 场景：home → forum → 帖子 → 后退 → forum → 后退 → home
const scenario1 = ['#/forum', '#/forum/post/123', '#/forum', '#/home'];
const s1names = scenario1.map(h => parseHash(h).name);
check('场景1: home→forum→帖子→后退→forum→后退→home',
  s1names[0] === 'forum' && s1names[1] === 'forumPost' && s1names[2] === 'forum' && s1names[3] === 'home',
  JSON.stringify(s1names));

// 场景：home → 资料页 → 后退 → home
const s2names = ['#/profile/abc', '#/home'].map(h => parseHash(h).name);
check('场景2: home→资料页→后退→home',
  s2names[0] === 'profile' && s2names[1] === 'home', JSON.stringify(s2names));

// 场景：论坛 → 帖子A → 后退 → 论坛 → 帖子B（不同帖子切换）
const s3names = ['#/forum', '#/forum/post/A', '#/forum', '#/forum/post/B'].map(h => parseHash(h).name + (parseHash(h).param ? '|'+parseHash(h).param : ''));
check('场景3: 帖子A→退→论坛→帖子B 各自正确',
  s3names[0]==='forum' && s3names[1]==='forumPost|A' && s3names[2]==='forum' && s3names[3]==='forumPost|B',
  JSON.stringify(s3names));

// 场景：直接访问深链接（刷新帖子页）
const s4 = parseHash('#/forum/post/999');
check('场景4: 直接访问 #/forum/post/999', s4.name === 'forumPost' && s4.param === '999');

console.log(`\n=== 通过 ${pass} / 失败 ${fail} ===`);
