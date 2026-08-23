// 91taffy 站业务 JS 语法检查脚本
// 用法: node check_js.js [html路径]
// 说明: 提取 index.html 中最后一个 <script> 块（业务脚本）并做语法检查
const fs = require('fs');
const path = require('path');
const file = process.argv[2] || path.join(__dirname, 'index.html');
const html = fs.readFileSync(file, 'utf8');
const opens = [];
let re = /<script[^>]*>/g, m;
while((m = re.exec(html)) !== null) opens.push(m.index);
if(!opens.length){ console.error('未找到 <script> 块'); process.exit(1); }
const lastOpen = opens[opens.length - 1];
const end = html.indexOf('</script>', lastOpen);
const js = html.slice(lastOpen + '<script>'.length, end);
const tmp = path.join(__dirname, '_check_bundle.js');
fs.writeFileSync(tmp, js);
console.log('业务脚本长度:', js.length);
// 语法检查（node --check 会在外部执行，这里只做输出辅助）
console.log('临时文件已生成: _check_bundle.js');
