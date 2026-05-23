# HeyCC（曾用名 Nibbi / CodexBar）项目规范

## 改完 Swift 代码后必须做的事

每次修改 `Sources/codexbar/` 下的任何 `.swift` 文件后，**默认跑 [`./build.sh`](build.sh)** 把 release 二进制打到 `HeyCC.app/`。不要把 `swift build`（debug 验证编译）当作完成——只有 `./build.sh` 才会真正更新菜单栏运行的那个 app。

流程：

1. 改代码
2. `swift build` 快速验证编译（可选，迭代多次时用）
3. `./build.sh` —— release 编译 + 打入 `HeyCC.app/Contents/MacOS/HeyCC` + ad-hoc 签名
4. 验证新代码在二进制里（中文文案用 `grep -a`，不要用 `strings` —— macOS 自带的 `strings` 默认只输出 ASCII，UTF-8 中文会被漏掉）

## 用户不主动要求时**不要**做的事

- 不要 `cp -r HeyCC.app /Applications/`（用户自己控制何时上线）
- 不要 kill 正在运行的 HeyCC 进程
- 不要 `git commit` / `git push`（用户口头说"提交"再做）

## 网络接口轮询的边界

- Claude OAuth 用量接口 `https://api.anthropic.com/api/oauth/usage`：默认 120s 一次，遇 429 已有退避（见 [AppDelegate.swift](Sources/codexbar/AppDelegate.swift) `nextAllowedRefresh`）。不要再降低这个间隔。
- Codex `https://chatgpt.com/backend-api/wham/usage`：同上节奏。
