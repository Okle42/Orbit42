# Orbit42 規格

一套「球體 AI 系統」：用哪一家的 AI 當大腦都能登入（Claude、ChatGPT、Gemini、Grok…），每個 AI 工作者是一顆繞著球體轉的衛星；
點衛星就在系統裡打開它真的終端機畫面，不用再開一堆終端機視窗。

## 終極目標（Keng 2026-11-23）

**Orbit42 要像 macOS 一樣，是一套「系統」等級的存在**——不是一個工具視窗：
開機就進到 Orbit42、先登入（各家 AI 帳號）、球體就是桌面、衛星就是一個個在跑的 AI（像 App）、所有工作都在它裡面完成，不必再回到 Finder、Ghostty。
往後每個決定都照這個方向：常駐、全螢幕桌面、登入畫面、多個 AI 同時跑、系統級的狀態（額度、溫度、風扇、硬碟、自檢）一眼看完。

## 架構

```
Orbit42（這個 App）
├ 球體畫面（three.js，網頁，Mac WKWebView）
├ 衛星終端機：xterm.js ＋ 原生虛擬終端機（forkpty），一顆衛星一個
├ 大腦接口（adapter）：各家官方 AI 工作程式
│   Claude → claude（Claude Code）
│   ChatGPT → codex（OpenAI Codex CLI）
│   Gemini → Antigravity CLI `agy`（Google；2026-05 起取代 Gemini CLI，本機已裝）
│   Grok → xAI（待定：CLI 或 API）
└ 共用核心：Engine/ 的 Orbit42Core（session 狀態、卡片、額度、自檢）
```

系統本身不當大腦：登入直接用各家自己的帳號（訂閱），工具、權限、更新都由各家維護；Orbit42 只做外殼、總覽和守門。

## 階段

| 階段 | 內容 | 驗收 | 狀態 |
|---|---|---|---|
| S1 衛星終端機 | 球體＋「＋」開新衛星；點衛星打開它的真終端機（xterm.js＋虛擬終端機）；背景 session 也能 attach 進來看 | 在球體按「＋」開一顆新衛星，點開就是真的終端機，在裡面跟 Claude 做完一件事，全程不碰 Ghostty | 進行中 |
| S2 大腦接口 | adapter：啟動、續接、狀態（忙／等你／做完）、額度；Claude → Codex → Antigravity（Gemini）→ Grok | 同一顆球上同時有 Claude 和 ChatGPT 的衛星 | |
| S3 登入 | 一打開先出登入畫面：Claude／ChatGPT／Gemini／Grok 的安裝與登入狀態，按登入在終端機跑官方登入；至少一家登入才能進入；球體「＋ 新衛星」只開登入過的大腦，選單有「帳號⋯」回登入頁 | 新電腦裝好就能登入使用 | 畫面完成（Claude 用 `claude auth status`、Gemini 讀 ~/.gemini/google_accounts.json、ChatGPT 看 ~/.codex/auth.json） |
| S4 cool42 併入 | 閘門（AI 開重工作前先問）與風扇守護程式改由系統管理 | 不另外裝 cool42 也有完整功能 | |
| S6 系統化 | 開機自動進 Orbit42（登入項目）、全螢幕桌面模式、像 macOS 登入畫面一樣先登入、Dock／選單列整合 | 開機後不用碰其他 App 就能工作 | |
| S5 取代Orbit42 | 球體分頁、播報、自檢、額度全部搬過來 | 只開 Orbit42 就能工作 | 進行中：完整球體已嵌入（Orbit42App.SphereEmbed），Orbit42 開著時停掉 Orbit42Agent、關掉再開回 |

## 決定紀錄

- 2026-11-23：衛星點開＝真的終端機畫面；終端機元件＝xterm.js（網頁型，跟球體同頁、之後 Windows 共用）；Grok＝xAI 的 Grok；也要接 Google 的 Gemini（走 Antigravity CLI，Gemini CLI 已被取代）
- 2026-11-23：AI 專用虛擬機（原本 v0 構想）先不做
- 2026-11-23：公開 repo（42 系列），授權與 Orbit42 相同（原始碼公開、非開源）

- 2026-11-23：Orbit42 取代 Orbit42Agent（同一顆引擎 `EngineMain.run`，Orbit42 加主視窗：完整球體＋右側衛星終端機）；Orbit42 拆出函式庫 Orbit42App
- 2026-11-23：Claude Code 的對話框（okle42 樣式）改黑白灰紅、終端機色票分深淺兩套，跟系統外觀切換

- 2026-11-25：拆掉從 Orbit42 帶進來的 3D 辦公室、大樓、村莊、地下室、城市、天氣與收件匣面板；Orbit42視窗只留智能體和工具列
