# Orbit42 交接（2026-11-23 上午，Bella）

**目標（Keng）：Orbit42 要像 macOS 一樣是「系統」**——開機就進、先登入各家 AI 帳號、球體＝桌面、衛星＝在跑的 AI、所有工作在裡面完成。規格與路線圖：docs/SPEC.md。

## 現況（都已推 main，App 已打包）
- repo：公開 Okle42/Orbit42（原始碼公開授權，同 ShoWork42）。依賴 ShoWork42 的 `ShoWorkCore`、`ShoWorkApp`（ShoWorkAgent 拆出的函式庫）
- App：`scripts/build_app.sh` → `~/Applications/Orbit42.app`（bundle id ai.okle42.orbit42，Apple Development 簽名），桌面有「Orbit42」捷徑；圖示 `swift scripts/make_icon.swift`
- 開 Orbit42 會 `launchctl bootout` ShoWorkAgent（同一顆引擎由 Orbit42 跑：`ShoWorkAgentMain.run(AgentOptions)`），關掉時 bootstrap 回來（AgentSwap）
- 畫面：登入畫面（Accounts.swift＋Web/login.html）→ 進入（登入卡飛出＋球從遠處拉近 karaIntro）→ 完整 ShoWork 球體（SphereEmbed.makeView，sphere.html?orbit=1）
- 衛星：球體「＋ 新衛星」選 Claude／Gemini（agy）／ChatGPT（codex，未裝），都用最高權限參數；點球上衛星：Orbit42 開的→開它的終端機、背景 session→attach、Ghostty 開的→照舊跳 Ghostty
- 衛星終端機＝原生小視窗 TermWindow.swift（拖標題列、右下角縮放、雙擊放大、紅灰白三顆燈：結束／收起／放大、記住位置）＋內容 Web/index.html?term=1（xterm.js 5.5、PTY Pty.swift）
- 終端機回答 OSC 11/10 與 CSI ?996n（深淺），等大小穩定才啟動程式（否則 Claude 排版會亂）
- 11-23：淺色終端機提高對比（底 #fbfbf9、字 #111）；球體 ◐ 換深淺 → 終端機／標題列／裡面的 Claude 跟著換；拖檔案（截圖）進終端機＝貼路徑；調大小停 300ms 才重量並送 Ctrl+L 重畫（之前拖動中一直重畫會亂）——這幾項 Keng 還沒實際試
- 11-23 散熱資訊拆成獨立「散熱」小卡（cardCool，右欄戰情下面）
- 全螢幕桌面模式預設開（⌃⌘F／球體 ⛶ 切換，記住）；主視窗最上方一條可拖動（11-23 剛修，Keng 還沒試）

## 測試（一律螢幕外）
```bash
cd ~/github-repos/Orbit42
swift package edit ShoWork42 --path ~/github-repos/_wt-ShoWork42-sphere   # 要同時改 ShoWork 端時；推之前 unedit
ORBIT_OFFSCREEN=1 SHOWORK_WEB_DIR=~/github-repos/_wt-ShoWork42-sphere/windows/ShoWork.Win/Board/Web \
  SHOWORK_TEST_SPHERE_SHOT=/tmp/x/s.png SHOWORK_TEST_SPHERE_JS='document.getElementById("bNewSat").click();setTimeout(()=>document.querySelector("#satMenu [data-brain=claude]").click(),300)' \
  ORBIT_TEST_JS='setTimeout(()=>orbitTest.type("回覆一個字：好"),24000);setTimeout(()=>orbitTest.type("\r"),25500)' \
  ORBIT_TEST_SHOT=/tmp/x/t.png ORBIT_TEST_SHOT_DELAY=42 ORBIT_TEST_QUIT=1 .build/debug/Orbit42
```
其他：`ORBIT_TEST_LOGIN_SHOT`（登入畫面）、`ORBIT_TEST_TERM_SHOT`＋`_DELAY`（原生小視窗）、`ORBIT_TEST_RAW`（錄 PTY 原始輸出查顏色碼）

## 坑
- okle42 樣式不能用 ANSI 色名（white/red）：Claude Code 會換成固定 RGB，不跟深淺 ⇒ 用主題鍵 text／subtle／inactive／error
- Keng 常在 Orbit42 裡用「背景 session」attach 看 Bella：**重開 Orbit42 前先查它有沒有子程序在用**（`pgrep -P <Orbit42 pid>`＋tty 最後輸入），有就不要自己重開
- 關任何程序前看終端機最後輸入時間（記憶 feedback_關程序前看終端機有沒有人在用）

## 還沒做／下一步
1. Keng 重開新版實測：拖視窗、三顆燈、淺色字、過場動畫、播報、空白鍵講話（Orbit42 新身分要重新允許輔助使用／麥克風／語音辨識）
2. S6 系統化：開機自動進 Orbit42（登入項目）→ 像 macOS 的登入畫面 → Dock／選單列整合
3. S2 大腦接口：各家狀態（忙／等你／做完）、續接、額度；Grok（xAI）接法待查
4. 安裝程式切換：showork_install 改裝 Orbit42、ShoWorkAgent 退成備援
5. codex 未安裝，ChatGPT 衛星與 `--dangerously-bypass-approvals-and-sandbox` 參數都沒實測
