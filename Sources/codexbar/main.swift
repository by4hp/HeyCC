import AppKit

// 个人版 CodexBar —— 菜单栏同时显示 Claude 与 Codex 的 5 小时用量。
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory) // 无 Dock 图标，只在菜单栏
app.run()
