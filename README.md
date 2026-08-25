# 91塔菲站 · 91taffy.com

永雏塔菲（Yongchu Taffy）粉丝社区网站。上线地址：https://www.91taffy.com

## 功能特性

- **动态表情评论区**：16 款塔菲动态 GIF 表情、图片评论、点赞、多维度排序、分页
- **粉丝论坛**：发帖 / 回帖 / 楼中楼、置顶、精华、公告、管理员管理
- **抽奖活动**：报名参与、中奖名单、禁抽名单、并发锁保证数据一致
- **用户系统**：邮箱验证码注册 / 登录、找回密码、个人主页、头像裁剪上传
- **管理后台**：用户管理、封禁、重置密码、删除账户、UID 冻结与回收

## 技术栈

- **前端**：原生 HTML / CSS / JavaScript 单页应用（SPA），Win7 Aero 立体风格，hash 路由
- **后端**：Supabase（PostgreSQL 数据库 + Auth 认证 + Storage 存储）
- **部署**：Vercel（GitHub push 到 `main` 自动部署）

## 目录结构

```
site/
├── index.html              # 前端单文件应用（页面结构 + 样式 + 业务脚本）
├── assets/                 # 静态资源（徽章、表情 GIF、默认头像、本地化 Supabase SDK）
├── supabase/
│   ├── migrations/         # 数据库迁移（按时间戳顺序，全部幂等）
│   ├── schema.sql          # 完整库表结构
│   └── config.toml         # Supabase CLI 配置
├── _test_*.js              # 逻辑与端到端测试（node 直接运行，无外部依赖）
├── check_js.js             # 提取 index.html 业务脚本做语法检查
├── robots.txt              # 搜索引擎爬虫规则
└── sitemap.xml             # 站点地图
```

## 本地开发

前端为纯静态单文件，直接打开 `index.html` 即可预览（登录 / 数据相关功能需连接 Supabase 项目）。

```bash
# 语法检查业务脚本
node check_js.js

# 运行测试
node _test_route.js
node _test_route_e2e.js
node _test_paging.js
node _test_floor.js
node _test_viewmode.js
node _test_viewmode_e2e.js
```

## 部署

1. 在 Vercel 导入本仓库，识别为静态项目后直接部署
2. 绑定域名 `91taffy.com`（DNS 解析到 Vercel）
3. 数据库结构变更通过 `supabase/migrations/` 管理，在 Supabase SQL Editor 执行

## 维护文档

- `Supabase邮件配置说明.md` — 邮件 / 验证码 SMTP 配置与 API 操作
- `验证码注册配置说明.md` — 自定义 SMTP 配置流程
- `Google收录操作指引.md` — Search Console 提交收录步骤

## License

个人站点项目，代码公开供学习参考。
