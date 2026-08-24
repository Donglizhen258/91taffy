# 91taffy Supabase 邮件配置 · 运维说明（2026-08-24 塔菲代改）

> 本文件记录已验证的 Supabase 邮件/验证码配置，供后续维护参考。
> 管理令牌存放在 `.env.local`（已被 gitignore，不会入库）。

## 当前生效配置（2026-08-24 通过 Management API 确认）

| 配置项 | 值 | 说明 |
|--------|-----|------|
| SMTP Host | `smtp.qq.com:465` | QQ 邮箱 SMTP（SSL） |
| SMTP 账号 | `taffy91@foxmail.com` | 发件人/认证账号一致 |
| SMTP 发件人 | `91塔菲站` | Sender name |
| 验证码位数 | `6` | 与前端 `maxlength=6` 一致 ✅ |
| 验证码有效期 | `600s`（10 分钟） | 与前端提示一致 ✅ |
| Magic Link 邮件模板 | `您的登录验证码是：{{ .Token }}，10 分钟内有效` | 用 Token 而非 ConfirmationURL → 发验证码而非链接 ✅ |
| Confirmation 模板 | 同上（Token） | signUp 验证邮件同样用验证码样式 |
| 主题（Magic Link） | `91塔菲站验证码` | |
| mailer_autoconfirm | `false` | 需要验证，符合注册流程 |

## 关键原理（避免再踩坑）

- Supabase 的 `signInWithOtp` / `signUp` 发出的邮件**内容由邮件模板决定**：
  - 模板含 `{{ .ConfirmationURL }}` → 用户收到**验证链接**
  - 模板含 `{{ .Token }}` → 用户收到 **6 位验证码**
- 两者共用同一底层实现，改 Magic Link 模板即可影响 OTP 邮件。
- 前端 `verifyOtp({ email, token, type:'email' })` 校验验证码，校验通过即进入登录态。

## 如何用 API 查看/修改（无需打开网页控制台）

```bash
# 查看当前 auth 配置（含全部邮件模板）
curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  "https://api.supabase.com/v1/projects/gxdmrwlttvwyzqusmgzz/config/auth" | jq

# 修改字段（示例：把验证码时长改回 1 小时）
curl -s -X PATCH -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mailer_otp_exp":3600}' \
  "https://api.supabase.com/v1/projects/gxdmrwlttvwyzqusmgzz/config/auth"
```

常用字段：`mailer_otp_length`（位数）、`mailer_otp_exp`（有效期秒）、`mailer_subjects_magic_link`、`mailer_templates_magic_link_content`、`smtp_host/smtp_port/smtp_user/smtp_pass/smtp_sender_name/smtp_admin_email`。

## 安全提醒

- `.env.local` 中的令牌即日生效、有效期 **1 年**，可随时在
  `https://supabase.com/dashboard/account/tokens` 点击 **Revoke** 使其立即失效。
- 若令牌曾出现在聊天/日志中，建议改完配置后 Revoke 并重发一个，降低泄露风险。