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

## 11-23 11:20 Keng 錄影回報後修的（已打包，等 Keng 重開實測）
- **調大小錯位的真正根因**：Pty.swift 用 `@_silgen_name("ioctl")` 自己宣告非可變參數版，Apple 晶片上可變參數走堆疊 ⇒ TIOCSWINSZ 從來沒成功，程式收不到 SIGWINCH。改用 Darwin 內建 `ioctl`。螢幕外重現＋驗證：`ORBIT_TEST_DRAG="<前綴>@<秒>"`（模擬拖右下角縮小→停→放大→停，倒出 `<前綴>_0/1/2.txt`）
- 拖檔案進終端機沒反應：WKWebView 自己重新註冊拖放、搶在小視窗前 ⇒ 改成 `DropWebView`（TermWindow.swift）本身接檔案轉路徑。**螢幕外無法模擬拖曳，要 Keng 實測**
- 終端機顏色只留黑白灰紅：色票的綠黃藍紫青改灰；Claude／狀態列的真彩色碼在 index.html `okColors()` 進畫面前改寫（紅橘→品牌紅、其他→同亮度灰）。表情符號（🌀）改不了
- 球體溫度環外加風扇轉速環（ShoWork42 a27f71d，LAYER 7，尖端標 RPM）
- 衛星終端機毛玻璃：TermWindow 底層 NSVisualEffectView（.withinWindow／.hudWindow），標題列 35% 底、終端機底色 #…8c（xterm allowTransparency）；**透明時不能用 WebGL addon（會殘影）**，小視窗改 DOM 繪圖。模糊效果螢幕外截圖拍不到，要實機看

## 11-23 中午最後狀態（Keng 準備 /clear）
- 已做且已打包、推 main（b8c451c）：帳號頁空白修好（疊放順序）、登入卡片等球拉遠到 0.8 秒才進場、終端機打開邊框閃紅光、衛星工作中紅色呼吸光
- Keng 還沒實際看：上面這些＋拖視窗、三顆燈、拖檔案、調大小不錯位、淺色對比、深淺連動
- 下一步：等 Keng 重開跑一遍完整流程、一次列出不順的地方；之後 S6 開機自動進 Orbit42

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
- **改完 Orbit42 一定要先跑一次螢幕外啟動（ORBIT_TEST_LOGIN_SHOT＋ORBIT_TEST_QUIT）再打包重開**：11-23 疊放順序修改沒先跑，App 一開就閃退三次。另外 Orbit42 閃退時不會把 ShoWorkAgent 開回來（atexit 沒跑），要手動 `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.okle42.showork.agent.plist` 或再開 Orbit42
- 疊放順序：球體 → 登入畫面 → 終端機小視窗（登入畫面放錯層會被球體蓋住）
- okle42 樣式不能用 ANSI 色名（white/red）：Claude Code 會換成固定 RGB，不跟深淺 ⇒ 用主題鍵 text／subtle／inactive／error
- Keng 常在 Orbit42 裡用「背景 session」attach 看 Bella：**重開 Orbit42 前先查它有沒有子程序在用**（`pgrep -P <Orbit42 pid>`＋tty 最後輸入），有就不要自己重開
- 關任何程序前看終端機最後輸入時間（記憶 feedback_關程序前看終端機有沒有人在用）

## 調大小後內容錯位（11-23 已處理，待 Keng 實測）
- 結論：採實驗 3（只 fit、不 reset、不送 Ctrl+L）——變窄時舊內容被切掉不錯位，拉寬回來；Ctrl+L／reset 才是錯位元兇
- 小視窗記住的大小一律 `TermWindowView.fit` 縮進目前 Orbit42 視窗（之前全螢幕記的大小在小視窗會超出）
- 現象：拖小視窗右下角改寬度後，之前輸出的表格／框線整片錯位（attach 看 Bella 的 session 也一樣）
- 實驗 1（commit 8944276，App 裡現在這版）：停 300ms 才 fit＋寬度變了送 Ctrl+L → 還是亂（舊內容被 xterm 按新寬度重新折行）
- 實驗 2：fit 後 `term.reset()` 再送 Ctrl+L → 更亂（推測 reset 把 Claude 收到 SIGWINCH 後的整頁重畫清掉，Ctrl+L 只重畫底部）
- 實驗 3（工作樹現在這版，未打包）：只 fit、不 reset、不送 Ctrl+L → 截圖內容整齊但右邊被切，**看起來 cols 沒變**（測試是把 #terms 寬度改 62%，要先確認 fit 有沒有真的跑、pty 有沒有收到新尺寸）
- 下一步：在測試裡印 orbitTest 的 cols 前後值＋ORBIT_TEST_RAW 看 Claude 收到 resize 後輸出什麼（是否 `\x1b[2J\x1b[3J` 整頁重印）；可能要關掉 xterm 的折行（reflow），或寬度變時先清捲軸再讓 Claude 自己重印
- 測試寫法：ORBIT_TEST_JS 裡 `setTimeout(()=>{document.getElementById("terms").style.width="62%"},42000)`，ORBIT_TEST_TERM_SHOT_DELAY=52

## 還沒做／下一步
1. Keng 重開新版實測：拖視窗、三顆燈、淺色字、過場動畫、播報、空白鍵講話（Orbit42 新身分要重新允許輔助使用／麥克風／語音辨識）
2. S6 系統化：開機自動進 Orbit42（登入項目）→ 像 macOS 的登入畫面 → Dock／選單列整合
3. S2 大腦接口：各家狀態（忙／等你／做完）、續接、額度；Grok（xAI）接法待查
4. 安裝程式切換：showork_install 改裝 Orbit42、ShoWorkAgent 退成備援
5. codex 未安裝，ChatGPT 衛星與 `--dangerously-bypass-approvals-and-sandbox` 參數都沒實測
