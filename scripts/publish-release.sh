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
"$GENERATE_APPCAST" --ed-key-file "$KEYS_DIR/eddsa_private_key" "$APPCAST_DIR"
echo "Appcast 產生於: $APPCAST_DIR/appcast.xml"
echo ""

# ============================================
# Step 2: Create GitHub Release
# ============================================
echo "=== Step 2: Creating GitHub Release ==="

if ! command -v gh &> /dev/null; then
    echo "ERROR: 找不到 gh CLI，請先安裝：brew install gh"
    exit 1
fi

# generate_appcast 可能在 APPCAST_DIR 產生 delta patch（給舊版用戶做增量更新），
# 但它猜測的下載網址是 raw.githubusercontent.com/<delta 檔名> —— 這個檔案從沒被
# 推上 git（releases/ 整個被 .gitignore），所以永遠 404。跟 DMG 一樣上傳成
# GitHub Release asset，下面 Step 3 再把 appcast.xml 裡的網址換成真正能下載的連結。
DELTA_FILES=("$APPCAST_DIR"/*.delta)
[ -e "${DELTA_FILES[0]}" ] || DELTA_FILES=()

if gh release view "v$VERSION" --repo "$GITHUB_REPO" &>/dev/null; then
    echo "Release v$VERSION 已存在，更新中..."
    gh release upload "v$VERSION" "$DMG_PATH" --repo "$GITHUB_REPO" --clobber
    if [ ${#DELTA_FILES[@]} -gt 0 ]; then
        echo "上傳 delta 更新檔..."
        gh release upload "v$VERSION" "${DELTA_FILES[@]}" --repo "$GITHUB_REPO" --clobber
    fi
else
    echo "建立 release v$VERSION..."
    gh release create "v$VERSION" "$DMG_PATH" \
        --repo "$GITHUB_REPO" \
        --title "$APP_NAME v$VERSION" \
        --notes "## $APP_NAME v$VERSION

### Installation
1. Download \`$APP_NAME-$VERSION.dmg\`
2. Open the DMG and drag $APP_NAME to Applications
3. Launch $APP_NAME from Applications
4. 因未經 Apple 公證，第一次開啟請「右鍵 → 打開」，或到「系統設定 → 隱私權與安全性」點「仍要打開」

### Auto-updates
After installation, $APP_NAME will automatically check for updates."
    if [ ${#DELTA_FILES[@]} -gt 0 ]; then
        echo "上傳 delta 更新檔..."
        gh release upload "v$VERSION" "${DELTA_FILES[@]}" --repo "$GITHUB_REPO" --clobber
    fi
fi

# GitHub 上傳時檔名裡的空白會變成句點，直接向 GitHub 查詢實際網址，不要自己猜檔名
GITHUB_DOWNLOAD_URL=$(gh release view "v$VERSION" --repo "$GITHUB_REPO" --json assets --jq '.assets[] | select(.name | endswith(".dmg")) | .url')
echo "GitHub release: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
echo "Download URL: $GITHUB_DOWNLOAD_URL"
echo ""

# ============================================
# Step 3: Publish appcast.xml to GitHub (raw file)
# ============================================
echo "=== Step 3: Publishing Appcast ==="

cp "$APPCAST_DIR/appcast.xml" "$APPCAST_ROOT"

# 把 generate_appcast 猜的下載網址（依 SUFeedURL 推斷，可能是 raw.githubusercontent 的假路徑
# 或空白未轉碼的檔名）換成真正的 GitHub release 下載連結。
# 只替換「這次發布版本」的那個 <item>（用檔名尾端 -$VERSION.dmg 精準比對），
# 不能用不限定版本的萬用 pattern — 否則會把其他版本（例如 1.5.0）的 enclosure url
# 也一起覆寫成這次的下載連結，汙染 appcast 歷史紀錄。
sed -i '' "s|url=\"[^\"]*-$VERSION.dmg\"|url=\"$GITHUB_DOWNLOAD_URL\"|g" "$APPCAST_ROOT"

# Delta 檔案同理：換成真正上傳到 GitHub Release 的下載連結。用檔名裡的版本區間
# （例如 "2026070703-20260707"）精準比對，同一個 release 可能有多個 delta。
for delta_file in "${DELTA_FILES[@]}"; do
    delta_base="$(basename "$delta_file" .delta)"
    version_span="${delta_base#"$APP_NAME"}"
    DELTA_DOWNLOAD_URL=$(gh release view "v$VERSION" --repo "$GITHUB_REPO" --json assets \
        --jq --arg span "$version_span" '.assets[] | select(.name | endswith(".delta") and contains($span)) | .url')
    if [ -n "$DELTA_DOWNLOAD_URL" ]; then
        sed -i '' "s|url=\"[^\"]*$version_span\.delta\"|url=\"$DELTA_DOWNLOAD_URL\"|g" "$APPCAST_ROOT"
        echo "Delta download URL ($version_span): $DELTA_DOWNLOAD_URL"
    else
        echo "警告：找不到 delta $version_span 的上傳網址，appcast 裡的連結可能仍是壞的"
    fi
done

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
