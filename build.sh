#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo "→ 编译 (release)…"
swift build -c release

BIN=".build/release/codexbar"
APP="CodexBar.app"

echo "→ 打包 $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/CodexBar"
cp Info.plist "$APP/Contents/Info.plist"

# ad-hoc 签名，避免 Gatekeeper 拦截
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ 完成：$(pwd)/$APP"
echo
echo "运行：  open \"$APP\""
echo "安装：  cp -r \"$APP\" /Applications/ && open /Applications/$APP"
