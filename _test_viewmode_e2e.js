// 视图模式切换 + 头像裁剪 Pointer Events 端到端验证（DOM mock 版）
// 运行：node _test_viewmode_e2e.js

// ---- 简易 DOM mock ----
const elements = {};
function makeEl(id){
  const el = {
    id,
    classes: new Set(),
    attrs: {},
    style: {}, textContent: '', innerHTML: '', value: '',
    classList: {
      add: c => elements[id].classes.add(c),
      remove: c => elements[id].classes.delete(c),
      toggle: (c, force) => {
        if(force === undefined){ if(elements[id].classes.has(c)) elements[id].classes.delete(c); else elements[id].classes.add(c); }
        else if(force) elements[id].classes.add(c); else elements[id].classes.delete(c);
      },
      contains: c => elements[id].classes.has(c)
    },
    getAttribute: k => elements[id].attrs[k] || null,
    setAttribute: (k, v) => { elements[id].attrs[k] = v; },
    removeAttribute: k => { delete elements[id].attrs[k]; },
    hasPointerCapture: () => false,
    releasePointerCapture: () => {},
    setPointerCapture: () => {}
  };
  elements[id] = el;
  return el;
}
['navModeIco','navModeText','navModeSwitch'].forEach(id => makeEl(id));
makeEl('cropBox');

const documentMock = {
  getElementById: id => elements[id] || null,
  documentElement: makeEl('html'),
  addEventListener: () => {},
  dispatchEvent: () => {}
};

// ---- 全局 mock ----
const store = {};
const localStorageMock = {
  getItem: k => (k in store ? store[k] : null),
  setItem: (k, v) => { store[k] = String(v); },
  removeItem: k => { delete store[k]; }
};
let innerWidth = 1280;
const windowMock = {
  innerWidth,
  addEventListener: () => {},
  dispatchEvent: () => {},
  Event: function(){}
};
// 供测试读取最新 innerWidth
Object.defineProperty(windowMock, 'innerWidth', { get: () => innerWidth });

// ---- 注入被测代码环境 ----
global.window = windowMock;
global.document = documentMock;
global.localStorage = localStorageMock;
// cycleViewMode 里会引用 currentRoute 和 switchView，提供桩
let currentRoute = 'home';
function switchView(){}

// ---- 从 index.html 抽取视图模式核心逻辑执行 ----
const fs = require('fs');
const src = fs.readFileSync(__dirname + '/index.html', 'utf8');
// 抽取视图模式函数块
const startMark = '// ========== 电脑版 / 移动版 视图模式切换 ==========';
const endMark = '// ================== 站内 hash 路由 ==================';
const s = src.indexOf(startMark);
const e = src.indexOf(endMark);
if(s < 0 || e < 0 || e <= s){ console.error('无法定位视图模式代码块'); process.exit(1); }
const code = src.slice(s, e);
// 执行
eval(code);

let pass = 0, fail = 0;
function check(name, cond){
  if(cond){ pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name); }
}
console.log('== 视图模式：初始化 ==');
check('初始 auto 无 data-mode', !document.documentElement.attrs['data-mode']);
check('电脑(auto) 按钮显示「切换移动版」', elements.navModeText.textContent === '切换移动版');
check('电脑(auto) 图标 🖥️', elements.navModeIco.textContent === '🖥️');

console.log('\n== 视图模式：切换为移动版 ==');
cycleViewMode();
check('mobile 模式设置 data-mode="mobile"', document.documentElement.attrs['data-mode'] === 'mobile');
check('按钮显示「切换电脑版」', elements.navModeText.textContent === '切换电脑版');
check('localStorage 持久化 mobile', localStorageMock.getItem('91taffy_view_mode') === 'mobile');

console.log('\n== 视图模式：回到 auto ==');
cycleViewMode();
check('auto 移除 data-mode', !document.documentElement.attrs['data-mode']);
check('电脑(auto) 又显示「切换移动版」', elements.navModeText.textContent === '切换移动版');

console.log('\n== 视图模式：强制电脑版（模拟手机宽度） ==');
innerWidth = 375;
check('手机(auto) 按钮显示「切换电脑版」', (function(){ applyViewMode(); return elements.navModeText.textContent; })() === '切换电脑版');
cycleViewMode(); // mobile -> auto -> pc（手机 auto 时切换 -> pc）
check('手机切一次 -> pc 模式', document.documentElement.attrs['data-mode'] === 'pc');
check('pc 模式按钮「切换移动版」', elements.navModeText.textContent === '切换移动版');

console.log('\n== 头像裁剪：Pointer Events ==');
// 检查 index.html 里的裁剪 HTML 绑定 + JS
check('cropBox 用 onpointerdown 绑定', src.includes('onpointerdown="startCropDrag(event)"'));
check('cropBox 有 onpointermove', src.includes('onpointermove="onCropDrag(event)"'));
check('cropBox 有 onpointerup', src.includes('onpointerup="endCropDrag(event)"'));
check('有 onpointercancel', src.includes('onpointercancel="endCropDrag(event)"'));
check('JS 用 setPointerCapture', src.includes('setPointerCapture(e.pointerId)'));
check('不再用 mousemove 全局监听', !src.includes("document.addEventListener('mousemove', onCropDrag)"));
check('crop-box touch-action:none', src.includes('touch-action:none'));
check('手机 480px 裁剪框加高', src.includes('@media (max-width:480px){.crop-box{height:300px}}'));

console.log('\n== 电脑版布局优化 ==');
check('.wrap 加宽到 1080px', src.includes('.wrap{max-width:1080px'));
check('h1 加大到 46px', src.includes('h1{font-size:46px'));
check('.paw 加大到 132px', src.includes('.paw{width:132px'));
check('card 内边距加大', src.includes('padding:32px 30px'));

console.log('\n结果：' + pass + ' 通过 / ' + fail + ' 失败');
process.exit(fail ? 1 : 0);
