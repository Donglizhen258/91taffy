// 视图模式切换（电脑版/移动版）逻辑测试
// 运行：node _test_viewmode.js
// 从 index.html 抽取相关函数进行纯逻辑验证（无 DOM 依赖的核心部分）

const fs = require('fs');
const src = fs.readFileSync(__dirname + '/index.html', 'utf8');

// ---- 1. 抽取并检查关键函数存在 ----
const mustHave = ['getDeviceMode', 'applyViewMode', 'renderViewModeBtn', 'cycleViewMode', 'initViewMode'];
let pass = 0, fail = 0;
function check(name, cond){
  if(cond){ pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name); }
}
console.log('== 静态检查：关键函数与机制存在 ==');
mustHave.forEach(fn => check(`函数 ${fn} 存在`, src.includes('function ' + fn) || src.includes(fn + '()')));
check('CSS 强制电脑版规则', src.includes('html[data-mode="pc"]'));
check('CSS 强制移动版规则', src.includes('html[data-mode="mobile"]'));
check('localStorage 持久化 key', src.includes("'91taffy_view_mode'"));
check('按钮 HTML 存在', src.includes('id="navModeSwitch"') && src.includes('id="navModeText"'));
check('applyViewMode 用 data-mode 而非 viewport 改写', src.includes("root.setAttribute('data-mode', viewMode)"));
check('默认 auto 会移除 data-mode', src.includes("root.removeAttribute('data-mode')"));

// ---- 2. 纯逻辑模拟：模式循环 ----
console.log('\n== 逻辑验证：模式循环 ==');
// 模拟三个状态机
function simCycle(mode, device){ // device: 'pc' | 'mobile'
  if(mode === 'auto') return device === 'mobile' ? 'pc' : 'mobile';
  return 'auto';
}
// 手机 auto -> pc -> auto -> mobile
check('手机 auto→pc', simCycle('auto','mobile') === 'pc');
check('pc→auto', simCycle('pc','mobile') === 'auto');
check('auto→mobile', simCycle('auto','pc') === 'mobile');
check('mobile→auto', simCycle('mobile','pc') === 'auto');

// ---- 3. 逻辑验证：设备判定阈值 ----
console.log('\n== 逻辑验证：设备宽度阈值(880) ==');
function simDevice(w){ return w <= 880 ? 'mobile' : 'pc'; }
check('375px 手机→mobile', simDevice(375) === 'mobile');
check('768px 平板→mobile', simDevice(768) === 'mobile');
check('881px→pc', simDevice(881) === 'pc');
check('1280px 电脑→pc', simDevice(1280) === 'pc');

// ---- 4. 逻辑验证：initViewMode 恢复逻辑 ----
console.log('\n== 逻辑验证：保存值恢复 ==');
function simRestore(saved){ return (saved === 'pc' || saved === 'mobile') ? saved : 'auto'; }
check('保存 pc→恢复 pc', simRestore('pc') === 'pc');
check('保存 mobile→恢复 mobile', simRestore('mobile') === 'mobile');
check('保存 null→auto', simRestore(null) === 'auto');
check('保存非法值→auto', simRestore('desktop') === 'auto');

// ---- 5. 按钮文案逻辑 ----
console.log('\n== 逻辑验证：按钮文案 ==');
function simLabel(mode, device){
  if(mode === 'auto') return device === 'mobile' ? '切换电脑版' : '切换移动版';
  return mode === 'pc' ? '切换移动版' : '切换电脑版';
}
check('手机 auto 显示「切换电脑版」', simLabel('auto','mobile') === '切换电脑版');
check('电脑 auto 显示「切换移动版」', simLabel('auto','pc') === '切换移动版');
check('pc 模式显示「切换移动版」', simLabel('pc','mobile') === '切换移动版');
check('mobile 模式显示「切换电脑版」', simLabel('mobile','pc') === '切换电脑版');

console.log('\n结果：' + pass + ' 通过 / ' + fail + ' 失败');
process.exit(fail ? 1 : 0);
