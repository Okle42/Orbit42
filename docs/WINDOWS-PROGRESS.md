# Orbit42 Windows 版進度

最後更新：2026-11-23 19:45（Fiona4）

## 架構
- `windows/Orbit42.Win/`（C#、WinForms、WebView2、ConPTY）＋ ShoWork42 的 `windows/ShoWork.Win`（ProjectReference，預設找旁邊的 ShoWork42 repo，`-p:ShoWork42Dir=` 可改）
- 主視窗＝戰情中心 Orbit 模式（只留球體鋪滿）→ 上面蓋登入畫面 → 再上面是衛星小視窗
- 三頁網頁跟 Mac 共用：球體 `sphere.html`（ShoWork42）、登入 `Web/login.html`、衛星終端機 `Web/index.html`

## 在 Surface 實測過（11-23 19:45，Surface 螢幕上正式跑）
- [x] 打包安裝：`pwsh windows\pack.ps1` → %LOCALAPPDATA%\Programs\Orbit42，桌面與開始選單有 Orbit42 捷徑（圖示同 Mac）
- [x] 開啟：先關掉 ShoWorkAgent（光暈、pipe 由 Orbit42 接手），全螢幕；結束時把 ShoWorkAgent 開回桌面
- [x] 登入畫面：跟 Mac 一樣（綠框、OKLE42 · ORBIT42），Claude 顯示已登入 Max
- [x] 進入 → 球體：3D 球、時鐘、額度卡、外環卡（含 DISK 硬碟環）、戰情 SESSION 卡、右上工具列
- [x] ＋新衛星選單：只有登入過的 Claude 可選，跟 Mac 一樣
- [x] Claude 衛星：真的 Claude Code 2.1.330 跑在 ConPTY 裡，打字、回覆、中文、狀態列都正常
- [x] 重開後衛星接回（--resume 同一段對話）；pack.ps1 用 quit.request 請 Orbit42 正常結束
- [x] 自動排版：衛星排進球體算好的空位（左右卡片之間），接回的衛星也會補排
- [x] 答案卡跳出時，蓋到它的衛星先藏起來，答完恢復（同 Mac）
- [x] 深淺切換：球體、衛星外框、終端機一起換（淺色紅、深色護眼綠）
- [x] 開／收衛星的縮放過場、打開閃綠框、工作中邊框呼吸
- [x] ShoWork 球體測試 4 項通過；Mac 版回歸（登入畫面）正常

## 跟 Mac 不同（做不到或 Windows 本來就沒有）
- 毛玻璃半透明：Windows 子視窗疊在網頁上不能透明，終端機底色是實色
- 外環卡的溫度／風扇／時脈／吃 CPU 的程式：Mac 靠 cool42（只有 Mac 版），Windows 筆電讀溫度要管理員權限
- 隊長這類「戰情中心持有的 session」：Windows 版 ShoWork 本來就沒有這種 session，不會出現

## 修過的坑
- ConPTY：父程式的 stdout 被導向時子程式輸出不進虛擬主控台 ⇒ STARTF_USESTDHANDLES 給空控制代碼
- 發佈：showork.exe 是獨立式 ⇒ 照 ShoWork pack.ps1 先單獨發佈再用 PackShowork 內嵌（NETSDK1151）
- 從 ssh 送關視窗送不到桌面工作階段 ⇒ quit.request 檔
- 換深淺時 WebView2 預設底色要跟著換（終端機底是半透明）
- Surface 的 Claude Code 11-11 自動更新壞掉（claude.exe 500 位元組）⇒ 11-23 npm 重裝 2.1.330

## iPhone 連接版（Keng 11-23 追加，排在 Windows 版之後）

## 測試方法
Mac 上跑 scratchpad 的 `orbit_win_test.sh '<環境變數 JSON>' [秒數]`：同步原始碼 → Surface 編譯 → 排程 Orbit42Test 在桌面 session 螢幕外跑 → 抓回截圖。
環境變數：ORBIT_OFFSCREEN、ORBIT_TEST_LOGIN_SHOT、ORBIT_TEST_TERM="<指令>@<txt>"、ORBIT_TEST_SHOT、ORBIT_TEST_QUIT、SHOWORK_DEBUG
