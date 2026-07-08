#!/bin/bash
# 把 create-dmg.sh 已經建置好的 DMG（ad-hoc 簽名，未公證）發布到 GitHub Release，
# 並用 Sparkle EdDSA 金鑰簽署、更新 appcast.xml 後推上 origin/main。
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
RELEASE_DIR="$PROJECT_DIR/releases"
KEYS_DIR="$PROJECT_DIR/.sparkle-keys"
APPCAST_ROOT="$PROJECT_DIR/appcast.xml"
APP_NAME="AI Island"
GITHUB_REPO="MisssssXie/AI-Island"

echo "=== Publishing Release ==="
echo ""

# 找到最新建置的 DMG（由 create-dmg.sh 產生）
DMG_SRC=$(find "$BUILD_DIR" -maxdepth 1 -name "$APP_NAME-v*.dmg" -type f | sort -V | tail -1)

if [ -z "$DMG_SRC" ]; then
    echo "ERROR: 找不到 DMG，請先執行 ./scripts/create-dmg.sh"
    exit 1
fi

echo "使用 DMG: $DMG_SRC"

# 從檔名解析版本號（AI Island-v1.5.0.dmg -> 1.5.0）
VERSION=$(basename "$DMG_SRC" .dmg | sed -E 's/.*-v//')
echo "Version: $VERSION"
echo ""

mkdir -p "$RELEASE_DIR"
DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"
cp "$DMG_SRC" "$DMG_PATH"

# ============================================
# Step 1: Sign for Sparkle and generate appcast
# ============================================
echo "=== Step 1: Signing for Sparkle ==="

SPARKLE_SIGN=""
GENERATE_APPCAST=""

POSSIBLE_PATHS=(
    "$HOME/Library/Developer/Xcode/DerivedData/ClaudeIsland-*/SourcePackages/artifacts/sparkle/Sparkle/bin"
)

for path_pattern in "${POSSIBLE_PATHS[@]}"; do
    for path in $path_pattern; do
        if [ -x "$path/sign_update" ]; then
            SPARKLE_SIGN="$path/sign_update"
            GENERATE_APPCAST="$path/generate_appcast"
            break 2
        fi
    done
done

if [ -z "$SPARKLE_SIGN" ]; then
    echo "ERROR: 找不到 Sparkle 工具，請先在 Xcode 建置一次專案（下載 Sparkle package）"
    exit 1
fi

if [ ! -f "$KEYS_DIR/eddsa_private_key" ]; then
    echo "ERROR: 找不到私鑰 $KEYS_DIR/eddsa_private_key，請先執行 ./scripts/generate-keys.sh"
    exit 1
fi

APPCAST_DIR="$RELEASE_DIR/appcast"
mkdir -p "$APPCAST_DIR"
cp "$DMG_PATH" "$APPCAST_DIR/"

echo "產生 appcast..."
# --maximum-deltas 0：不產生 delta patch。delta 檔名只含版本區間、DMG 檔名又只用
# marketing version 命名，同一個 marketing version 重新打包（例如同版號改 build number
# 修 bug）時，新 DMG 會覆寫舊 DMG 的 GitHub release asset，但舊的 appcast item 仍留著
# 舊的簽章/長度，導致該 item 失效。乾脆不產生 delta，簡化維護。
"$GENERATE_APPCAST" --ed-key-file "$KEYS_DIR/eddsa_private_key" --maximum-deltas 0 "$APPCAST_DIR"
echo "Appcast 產生於: $APPCAST_DIR/appcast.xml"
echo ""

# ============================================
# Step 2: Prepare Release Notes
# ============================================
echo "=== Step 2: Preparing Release Notes ==="

NOTES_DIR="$PROJECT_DIR/releases/notes"
mkdir -p "$NOTES_DIR"
NOTES_FILE="$NOTES_DIR/v$VERSION.md"

if [ ! -f "$NOTES_FILE" ]; then
    echo "找不到 $NOTES_FILE，從 git commit 產生 changelog 草稿..."
    # 找上一個版本 tag（排除本次版本），作為 changelog 比較起點
    PREV_TAG=$(git -C "$PROJECT_DIR" tag --sort=-v:refname | grep -v "^v$VERSION$" | head -1)
    if [ -n "$PREV_TAG" ]; then
        RANGE="$PREV_TAG..HEAD"
        echo "  比較範圍: $RANGE"
    else
        RANGE="HEAD"
        echo "  找不到前一個 tag，使用全部 commit"
    fi
    # 只取 feat / fix，去掉 conventional commit 前綴，轉成 markdown bullet
    git -C "$PROJECT_DIR" log --pretty=format:'%s' "$RANGE" \
        | grep -E '^(feat|fix)(\(.+\))?:' \
        | sed -E 's/^(feat|fix)(\(.+\))?:[[:space:]]*/- /' \
        > "$NOTES_FILE" || true
    if [ ! -s "$NOTES_FILE" ]; then
        echo "- " > "$NOTES_FILE"
    fi
    echo ""
    echo "已產生草稿："
    echo "----------------------------------------"
    cat "$NOTES_FILE"
    echo "----------------------------------------"
    echo ""
    if [ -n "${EDITOR:-}" ]; then
        "$EDITOR" "$NOTES_FILE"
    else
        echo "請編輯 $NOTES_FILE（潤飾 changelog），完成後回來按 Enter 繼續，或 Ctrl+C 中止。"
        read -r _ || true
    fi
else
    echo "使用現有 changelog: $NOTES_FILE"
fi

# 組出完整的 release notes：標題 + Changelog（讀檔）+ 固定的 Installation / Auto-updates
NOTES_BODY="$(mktemp)"
{
    echo "## $APP_NAME v$VERSION"
    echo ""
    echo "### Changelog"
    cat "$NOTES_FILE"
    echo ""
    cat <<'STATIC_NOTES'
### Installation
1. 下載 `.dmg` 檔案
2. 打開 DMG，將 **AI Island** 拖到 **Applications** 資料夾
3. 再去雙擊 App 打開 AI Island，此時**首次打開會出現警告 ⚠️，先不要丟垃圾桶！** 因為此版本沒有 Apple Developer 簽名
4. 請依照以下方式解除：
   - 方式 A：到 **系統設定 → 隱私權與安全性**，往下滑找到「已阻擋 AI Island」，點擊 **強制打開**
   - 方式 B：打開終端機，輸入以下指令後即可正常打開：
     ```bash
     xattr -cr /Applications/AI\ Island.app
     ```
5. 開啟**輔助使用權限**（視窗切換功能需要）：系統設定 → 隱私權與安全性 → 輔助使用 → 加入 AI Island 並開啟

### Auto-updates
After installation, AI Island will automatically check for updates.
STATIC_NOTES
} > "$NOTES_BODY"

echo "Release notes 已準備完成。"
echo ""

# ============================================
# Step 3: Create GitHub Release
# ============================================
echo "=== Step 3: Creating GitHub Release ==="

if ! command -v gh &> /dev/null; then
    echo "ERROR: 找不到 gh CLI，請先安裝：brew install gh"
    exit 1
fi

if gh release view "v$VERSION" --repo "$GITHUB_REPO" &>/dev/null; then
    echo "Release v$VERSION 已存在，更新 DMG 與 release notes..."
    gh release upload "v$VERSION" "$DMG_PATH" --repo "$GITHUB_REPO" --clobber
    gh release edit "v$VERSION" \
        --repo "$GITHUB_REPO" \
        --title "$APP_NAME v$VERSION" \
        --notes-file "$NOTES_BODY"
else
    echo "建立 release v$VERSION..."
    gh release create "v$VERSION" "$DMG_PATH" \
        --repo "$GITHUB_REPO" \
        --title "$APP_NAME v$VERSION" \
        --notes-file "$NOTES_BODY"
fi

rm -f "$NOTES_BODY"

# GitHub 上傳時檔名裡的空白會變成句點，直接向 GitHub 查詢實際網址，不要自己猜檔名
GITHUB_DOWNLOAD_URL=$(gh release view "v$VERSION" --repo "$GITHUB_REPO" --json assets --jq '.assets[] | select(.name | endswith(".dmg")) | .url')
echo "GitHub release: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
echo "Download URL: $GITHUB_DOWNLOAD_URL"
echo ""

# ============================================
# Step 4: Publish appcast.xml to GitHub (raw file)
# ============================================
echo "=== Step 4: Publishing Appcast ==="

cp "$APPCAST_DIR/appcast.xml" "$APPCAST_ROOT"

# 把 generate_appcast 猜的下載網址（依 SUFeedURL 推斷，可能是 raw.githubusercontent 的假路徑
# 或空白未轉碼的檔名）換成真正的 GitHub release 下載連結。
# 只替換「這次發布版本」的那個 <item>（用檔名尾端 -$VERSION.dmg 精準比對），
# 不能用不限定版本的萬用 pattern — 否則會把其他版本（例如 1.5.0）的 enclosure url
# 也一起覆寫成這次的下載連結，汙染 appcast 歷史紀錄。
sed -i '' "s|url=\"[^\"]*-$VERSION.dmg\"|url=\"$GITHUB_DOWNLOAD_URL\"|g" "$APPCAST_ROOT"

echo "appcast.xml 已更新: $APPCAST_ROOT"
echo "發布網址: https://raw.githubusercontent.com/$GITHUB_REPO/main/appcast.xml"
echo ""

cd "$PROJECT_DIR"
git add appcast.xml
if git diff --cached --quiet -- appcast.xml; then
    echo "appcast.xml 內容沒有變化，略過 commit。"
else
    git commit -m "chore: update appcast.xml for v$VERSION"
    git push origin main
    echo "appcast.xml 已推送。"
fi

echo ""
echo "=== 發布完成 ==="
echo "  - DMG: $DMG_PATH"
echo "  - GitHub: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
echo "  - Appcast feed: https://raw.githubusercontent.com/$GITHUB_REPO/main/appcast.xml"
