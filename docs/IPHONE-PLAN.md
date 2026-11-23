# Orbit42 iPhone 連接版：規劃

2026-11-23（Fiona4）。Keng 追加：Windows 版之後做 iPhone 連接版。

## 現有基礎（不用從零做）
- ShoWork42 已有「網頁版戰情中心」（`ShoWorkCore/WebBoard.swift`＋`ShoWorkApp/WebServer.swift`，11-10）：
  - 只綁 Tailscale 位址（100.64.0.0/10），不開在區網、不開在網際網路
  - 每台一組隨機 token，所有請求都要帶；動作只收 POST＋JSON＋自訂標頭；限頻；稽核檔 web/audit.jsonl
  - 能做的只有五種：回答答案卡、傳話、派工、取消派工、收件匣 ack；**不能跑指令、不能打字進終端機**
  - 預設關，`showork web enable` 才開（目前這台沒開）
- Orbit42 把整個 ShoWork 引擎包在自己裡面 ⇒ 這個伺服器在 Orbit42 裡也會跑
- 這台 Mac 有 Tailscale；球體 sphere.html、衛星終端機 index.html（xterm.js）都是網頁，手機瀏覽器能直接用

## 做法（建議：網頁版、加到主畫面，不上架）
iPhone 用 Safari 經 Tailscale 開 `http://<Mac 的 Tailscale IP>:<埠>/orbit`，加到主畫面＝像 App 一樣全螢幕。

| 階段 | 內容 |
|---|---|
| P1 | 手機版球體：sphere.html 直式排版（球在上、戰情卡／答案卡在下），資料沿用網頁戰情中心那份 |
| P2 | 答案卡、權限卡：手機上按選項就送回（走現有 BoardActions.answer，安全規則不變） |
| P3 | 衛星畫面：列出 Orbit42 開著的衛星，點進去看即時終端機畫面（唯讀，xterm.js＋伺服器推送） |
| P4（要 Keng 決定）| 在衛星裡打字、開新衛星＝從手機遠端操作 Mac 上最高權限的 AI |

## 要 Keng 決定的
1. 手機能不能在衛星裡打字（P4）。能的話要加強：每台手機各自配對、可以撤銷、每次輸入記稽核、可選擇只允許特定衛星
2. 網頁版（加到主畫面，馬上能用、不用審核）或原生 App（TestFlight／上架，推播通知比較好做）

## 11-23 決定與進度
- Keng 選：**原生 iPhone App，走 TestFlight**。打字沒選 ⇒ 第一版只做「看＋回答答案卡」（衛星畫面唯讀）
- 已做（本機 commit）：
  - ShoWork42（sphere 分支）：網頁戰情中心加唯讀端點 /api/sphere、/api/sats、/api/sat（Tailscale＋token，含測試 15 項過）；球體 ?phone 手機版排版
  - Orbit42 Mac：衛星清單（附 Claude session id）與終端機輸出（含行列數）掛勾；衛星網頁 ?mirror 鏡像模式；ORBIT_TEST_REMOTE 測試過
  - iOS App（ios/，`cd ios && xcodegen`）：連線畫面（貼網址／掃 QR／示範）、球體分頁（同一份 sphere.html，按答案卡選項送 /api/answer）、衛星分頁（唯讀鏡像，每秒續讀）。網址與密碼存鑰匙圈
  - 模擬器示範模式驗過：球體、答案卡貼底整排、衛星鏡像
- 還要 Keng：
  1. App Store Connect 用 Okle42 團隊開 App（Bundle ID ai.okle42.orbit42.phone）、確認上傳用的帳號或 API 金鑰（之前那兩把是學弟 Gate25 的，不能用）
  2. iPhone 裝 Tailscale、登入跟 Mac 同一個帳號（okle42.ai）
  3. Mac 上跑 `showork web enable`（打開網頁戰情中心，只綁 Tailscale），把印出的網址貼進 App
