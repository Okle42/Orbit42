# Fiona4 交接（2026-11-23 21:45）

## 已完成（都在本機 commit，**沒有 push**：Okle42 要 Keng 審過才推）
- Orbit42 Windows 版：windows/Orbit42.Win＋pack.ps1，Surface 螢幕上實測完整流程（docs/WINDOWS-PROGRESS.md）
- iPhone App（ios/，xcodegen）：內建 Tailscale（TailscaleKit，框架不進 git，見 ios/README.md）、球體、衛星唯讀鏡像、回答答案卡
  - 已裝在 Keng 的 iPhone 16 Pro Max（devicectl），配對完成、連線穩（1 分鐘成功 51／失敗 1）
  - TestFlight 只有 build 1（內建 Tailscale 之前的舊版）；要新版得重出 build（上傳要 Keng 放行）
- Mac 端：ShoWork42 sphere 分支加唯讀端點 /api/sphere、/api/sats、/api/sat（41414d9）、球體 ?phone（61b62c2）、語音字重複修正（f719068，已換進 ~/Applications/Orbit42.app 的 Web/sphere.html）
- 配對：桌面「Orbit42 手機配對.command」→ scripts/phone_pair.sh（Keng 本人跑；不再換密碼；8742 被 AIStar 佔走 ⇒ 網頁戰情中心用 8743）
- Tailscale：刪掉 orbit42-tsprobe；留 Mac、Samsung A27（Keng 的）、orbit42-phone

## 未完成／下一步
1. **（最優先，Keng 21:47 回報）語音輸入常被打斷**：字重複已修好（Keng 實測長句不重複），但在 Orbit42 答案卡補充框講話時，macOS 聽寫常自己停掉、要手動再啟動。
   懷疑方向（還沒驗）：①球體播報（karaToast／TTS 唸 session 狀態）一出聲就搶走麥克風，聽寫停掉 ②ShoWork 引擎的光暈／面板視窗 orderFront 搶走 key window ③renderAsk 簽名變了重畫整張卡（輸入框被換掉）④Orbit42 原生 watchAskCard／raise 改 first responder。
   先查：Keng 講話時是不是剛好有播報（SphereAudio、karaToast 時間點）；有輸入框焦點時暫停播報／不重畫答案卡
2. （已確認）字不再重複
2. 要 push 的話先問 Keng（Orbit42 main、ShoWork42 bella/sphere-tab）
3. 新版 iPhone 上 TestFlight：archive → Xcode Organizer 或 exportArchive（上傳會被閘門擋，要 Keng 放行）
4. 手機打字進衛星（P4）Keng 還沒決定
5. 模擬器跑不了 TailscaleKit（只有真機 arm64），要模擬器得另編 make ios-sim

## 坑
- showork web enable／rotate 在 Claude Code 裡會被拒（設計如此：密碼只給本人）
- 手機截圖：開著 iPhone 鏡像輸出時 devicectl 截圖是黑的，改截鏡像視窗
- ShoWork42 sphere 分支有別人沒 commit 的改動（球體→智能體改名等），commit 時只 apply 自己的 hunk
