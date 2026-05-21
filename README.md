# codexbar-mini

把 **Claude Code** 与 **Codex** 的用量额度塞进 macOS 菜单栏的小工具。一眼看到两边的 5 小时额度还剩多少，不用切到终端敲 `/status`，也不用翻网页。

> 个人自用的精简版，灵感与 Claude / Codex 品牌图标来自 [steipete/CodexBar](https://github.com/steipete/CodexBar)。

## 功能

- **菜单栏常驻** —— 直接显示 Claude 与 Codex 的 5 小时额度百分比，颜色随用量变化（白 → 橙 → 红）。
- **下拉菜单** —— 5 小时 / 7 天额度进度条 + 重置倒计时，一键「立即刷新」。
- **刘海悬浮面板**（带刘海的 Mac）—— 鼠标移到刘海上即展开，显示额度、订阅套餐、续费倒计时，以及最近 7 天每小时 token 用量热力图。
- **DeepSeek 俏皮总结**（可选）—— 每 30 分钟调用一次 DeepSeek，结合当前用量与续费时间，生成一句俏皮的中文总结与提醒，带打字机逐字浮现动效。

## 环境要求

- macOS 13 及以上（刘海面板需要带刘海的机型，其余功能不挑机型）
- Swift 6 工具链（Xcode 16+ 或独立 Swift toolchain）
- 已在终端登录过 `claude` 与 `codex` CLI —— 用于读取本地凭证

## 构建与安装

```bash
git clone https://github.com/by4hp/codexbar-mini.git
cd codexbar-mini
./build.sh
open CodexBar.app
```

装进「应用程序」：

```bash
cp -r CodexBar.app /Applications/ && open /Applications/CodexBar.app
```

App 没有 Dock 图标，只待在菜单栏。

## 配置 DeepSeek 俏皮总结（可选）

不配置也能正常用，只是看不到面板底部那行俏皮话。

1. 到 [DeepSeek 开放平台](https://platform.deepseek.com/api_keys) 申请一个 API Key。
2. 编辑 `~/.dee_codexbar/config.json`（首次运行 App 会自动生成模板），把 Key 填进去：

   ```json
   {
     "deepseek_api_key": "sk-你的key"
   }
   ```

3. 重启 App。文案在启动后生成一次，之后每 30 分钟刷新；点菜单里的「立即刷新」也会重新生成。

用的是 `deepseek-v4-flash` 模型并关闭了思考模式，单次约 30 token，成本基本可忽略。

## 个性化

订阅套餐与每月续费日是写死的个人值，在 [`Sources/codexbar/Subscription.swift`](Sources/codexbar/Subscription.swift) 里改成自己的：

```swift
let claudeSubscription = Subscription(plan: "5× Max", renewalDay: 3)
let codexSubscription  = Subscription(plan: "Plus",   renewalDay: 19)
```

## 隐私说明

- 额度数据来自各家**官方接口**：Claude 走 `api.anthropic.com/api/oauth/usage`，Codex 走 `chatgpt.com/backend-api/wham/usage`；凭证从本机钥匙串 / `~/.codex/auth.json` 读取，只用于这两个请求。
- 热力图通过扫描本地会话日志（`~/.claude/projects`、`~/.codex/sessions`）统计 token，**全程在本机完成**。
- 仅当你配置了 DeepSeek Key 时，才会把**用量百分比、续费日期等概要信息**（不含任何代码或对话内容）发送给 DeepSeek 用于生成文案。

## 项目结构

| 文件 | 作用 |
| --- | --- |
| `Usage.swift` | 读取凭证、拉取 Claude / Codex 官方用量接口 |
| `History.swift` | 扫描本地会话日志，聚合 7 天 × 24 小时 token 热力图 |
| `Subscription.swift` | 订阅套餐与每月续费日计算 |
| `Quip.swift` | 调用 DeepSeek 生成俏皮总结 |
| `AppDelegate.swift` | 菜单栏图标、下拉菜单、定时刷新 |
| `NotchController.swift` / `NotchPanel.swift` | 刘海悬浮面板的定位与界面 |

## 致谢

灵感与 Claude / Codex 品牌图标来自 [steipete/CodexBar](https://github.com/steipete/CodexBar)。

## License

[MIT](LICENSE)
