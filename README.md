<div align="center">
  <img src="img/128.png" alt="Claude Island" width="128" height="128">
  <h3>AI-Island</h3>
  <p>這是基於 <a href="https://github.com/sherry30219-byte/claude-island-modify">claude-island-modify</a> 進行的調整版本，詳細修改項目以及安裝方法可以查看下方 Fork。</p>
  <a href="https://github.com/sherry30219-byte/claude-island-modify/releases/latest">
    <img src="https://img.shields.io/badge/下載-DMG-blue?style=for-the-badge" alt="下載 DMG" />
  </a>
</div>

## 功能

- **瀏海 UI** — 從 MacBook 瀏海位置展開的動畫覆蓋層
- **即時 Session 監控** — 同時追蹤多個 Claude Code session 的狀態
- **權限審批** — 直接在瀏海上批准或拒絕工具執行，不需要切換到終端機，或是開啟Auto自動核准模式
- **聊天記錄** — 查看完整對話歷史，支援 Markdown 渲染
- **自動安裝** — 首次啟動時自動安裝 Hooks

## 系統需求

- macOS 15.6+
- Claude Code CLI

## 安裝

### 方法一：下載 DMG（推薦）

[點擊下載最新版本](https://github.com/sherry30219-byte/claude-island-modify/releases/latest)

1. 下載 `.dmg` 檔案
2. 打開 DMG，將 **Claude Island** 拖到 **Applications** 資料夾
3. 再去雙擊 App 打開 Claude Island，此時**首次打開會出現警告 ⚠️，先不要丟垃圾桶！**
   因為此版本沒有 Apple Developer 簽名，加入 Apple Developer Program 一年要 $99 USD
4. 請依照以下方式解除：
   - 方式 A：到 **系統設定 → 隱私權與安全性**，往下滑找到「已阻擋 Claude Island」，點擊 **強制打開**
   
   - 方式 B：打開終端機，輸入以下指令後即可正常打開：
     ```bash
     xattr -cr /Applications/Claude\ Island.app
     ```
4. 開啟**輔助使用權限**（視窗切換功能需要）：系統設定 → 隱私權與安全性 → 輔助使用 → 加入 Claude Island 並開啟

### 方法二：從原始碼建置

```bash
git clone https://github.com/sherry30219-byte/claude-island-modify.git
cd claude-island-modify
```

1. 雙擊 `ClaudeIsland.xcodeproj` 開啟 Xcode
2. **Signing & Capabilities** → 將 **Team** 改為你的 Apple ID，**Bundle Identifier** 改為獨特值
3. 按 `⌘R` 建置並執行
4. 開啟輔助使用權限（同上方法一步驟 4）

## 運作方式

Claude Island 會在 `~/.claude/hooks/` 安裝 hooks，透過 Unix socket 傳遞 session 狀態。應用程式監聽事件並在瀏海覆蓋層上顯示。

當 Claude 需要執行工具的權限時，瀏海會展開並顯示批准/拒絕按鈕，不需要切換到終端機。

## 修改項目（Fork）

此 Fork 版本包含以下優化：

- **點擊切換視窗（智慧視窗匹配）** — 單擊 session 即可精準跳到對應的 VS Code / Cursor / 終端機視窗。即使同時開啟多個編輯器視窗，也能透過 AppleScript + System Events 比對視窗標題，正確切換到該專案的視窗。不需要 yabai。切換後靈動島自動收合。
```bash
  ⚠️ **已知問題**：此功能在 macOS 15.6 上可能失效，疑似與 `NSRunningApplication.activate` 棄用及 Automation 權限變更有關，尚未完全修復。
```
- **Hover 即展開** — 滑鼠移到靈動島立即展開，移除原本 1 秒的延遲。滑鼠離開後自動收合。
- **常駐顯示** — 靈動島始終可見，並顯示目前 session 數量。展開後右上角有最小化按鈕可手動隱藏。
- **動態面板高度** — 面板高度依據 session 數量自動調整，不再固定高度。
- **Session 資訊強化** — 每個 session 列顯示三行：專案名稱、你的最新提問、目前工具/狀態。
- **非 ASCII 路徑支援** — 修復專案路徑包含中文、日文等非 ASCII 字元時，JSONL 解析失敗的問題。
- **移除 Check for Updates** — 設定選單移除了更新檢查功能。因此為開源讓大家自己調整的版本。
- **GitHub 連結重新命名** — 「Star on GitHub」改為「Original Source on GitHub」以標示此為 Fork 版本。

## 數據分析

Claude Island 使用 Mixpanel 收集匿名使用數據：

- **App Launched** — 應用程式版本、建置編號、macOS 版本
- **Session Started** — 偵測到新的 Claude Code session 時

不會收集任何個人資料或對話內容。

## 授權

Apache 2.0
