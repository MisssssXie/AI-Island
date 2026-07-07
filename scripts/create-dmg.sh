#!/bin/bash
# 簡易打包腳本：Build Release + 產生可拖拉安裝的 DMG
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
DMG_DIR="$BUILD_DIR/dmg"
APP_NAME="AI Island"

echo "=== 建置 $APP_NAME ==="
echo ""

# 清理舊的 build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cd "$PROJECT_DIR"

# Build Release
# 用 ad-hoc 簽名（Sign to Run Locally），不需要對到任何 Apple Developer 憑證/帳號，
# 也不會用到 notarize（那需要付費 Developer Program 帳號）。
echo "正在建置 Release 版本..."
xcodebuild -scheme ClaudeIsland \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/derived" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="-" \
    DEVELOPMENT_TEAM="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    build 2>&1 | tail -5

# 找到 .app
APP_PATH=$(find "$BUILD_DIR/derived/Build/Products/Release" -maxdepth 1 -name "*.app" -type d | head -1)

if [ -z "$APP_PATH" ]; then
    echo "錯誤：找不到建置的 .app"
    exit 1
fi

echo "找到 App：$APP_PATH"
echo ""

# 取得版本號
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "1.0")

# 準備 DMG 內容
echo "=== 準備 DMG ==="
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"

# 複製 .app
cp -R "$APP_PATH" "$DMG_DIR/$APP_NAME.app"

# 產生 DMG
DMG_PATH="$BUILD_DIR/$APP_NAME-v$VERSION.dmg"
rm -f "$DMG_PATH"

echo "正在產生 DMG..."

# 優先用 create-dmg（更漂亮），沒有就用 hdiutil
if command -v create-dmg &> /dev/null; then
    create-dmg \
        --volname "$APP_NAME" \
        --background "$PROJECT_DIR/img/DMG_BG.jpg" \
        --window-size 600 400 \
        --icon-size 120 \
        --icon "$APP_NAME.app" 150 200 \
        --app-drop-link 450 200 \
        --hide-extension "$APP_NAME.app" \
        "$DMG_PATH" \
        "$DMG_DIR"
else
    hdiutil create -volname "$APP_NAME" \
        -srcfolder "$DMG_DIR" \
        -ov -format UDZO \
        "$DMG_PATH"
fi

# 清理暫存資料夾
rm -rf "$DMG_DIR"

echo ""
echo "=== 完成 ==="
echo ""
echo "DMG 已產生：$DMG_PATH"
echo "大小：$(du -h "$DMG_PATH" | cut -f1)"
echo ""
echo "注意：因為沒有 Apple Developer 簽名，使用者首次打開需要："
echo "  右鍵 → 打開，或到 系統設定 → 隱私權與安全性 點「仍要打開」"
