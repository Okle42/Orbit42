# Orbit42 Windows 版進度

最後更新：2026-11-23 18:55（Fiona4）

## 架構
- `windows/Orbit42.Win/`（C#、WinForms、WebView2、ConPTY）＋ ShoWork42 的 `windows/ShoWork.Win`（ProjectReference，預設找旁邊的 ShoWork42 repo，`-p:ShoWork42Dir=` 可改）
- 主視窗＝戰情中心 Orbit 模式（只留球體鋪滿）→ 上面蓋登入畫面 → 再上面是衛星小視窗
- 三頁網頁跟 Mac 共用：球體 `sphere.html`（ShoWork42）、登入 `Web/login.html`、衛星終端機 `Web/index.html`

## 在 Surface 實測過（螢幕外，11-23）
- [x] 編譯 0 警告 0 錯誤
- [x] 登入畫面：跟 Mac 一樣（綠框、OKLE42 · ORBIT42），各家安裝／登入狀態偵測
- [x] 衛星終端機：ConPTY 真終端機、xterm 顯示、中文正確、細捲軸
- [x] 衛星小視窗：三顆燈（深色綠／灰／白）、標題、圓角、打開閃綠框
- [x] 整個主視窗：球體＋工具列（＋新衛星、全螢幕、⋯、深淺、聲音）＋衛星疊在上面

## 還沒做／跟 Mac 不同
- [ ] 正式模式實跑（會先關掉 Surface 上的 ShoWorkAgent、全螢幕開在 Surface 螢幕上）
- [ ] 打包成安裝檔＋桌面捷徑
- [ ] 隊長這類「戰情中心持有的 session」：Windows 沒有工作視窗，點了照舊跳視窗
- [ ] 毛玻璃半透明：Windows 子視窗疊在網頁上不能透明，終端機底色是實色
- [ ] 開／收衛星的縮放淡入動畫：Windows 直接出現／消失
- [ ] 球體左欄的硬碟、溫度量表：Windows 版 ShoWork 本來就還沒有這些資料
- [ ] Surface 的 Claude Code 壞了（claude.exe 只剩 500 位元組、claude.cmd 不見，約 11-11 自動更新失敗），重裝要 Keng 同意

## iPhone 連接版（Keng 11-23 追加，排在 Windows 版之後）

## 測試方法
Mac 上跑 scratchpad 的 `orbit_win_test.sh '<環境變數 JSON>' [秒數]`：同步原始碼 → Surface 編譯 → 排程 Orbit42Test 在桌面 session 螢幕外跑 → 抓回截圖。
環境變數：ORBIT_OFFSCREEN、ORBIT_TEST_LOGIN_SHOT、ORBIT_TEST_TERM="<指令>@<txt>"、ORBIT_TEST_SHOT、ORBIT_TEST_QUIT、SHOWORK_DEBUG
