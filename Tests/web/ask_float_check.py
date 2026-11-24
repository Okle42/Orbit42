#!/usr/bin/env python3
"""答案卡浮層（ask.html）自動檢查：假題目＋無頭 Chrome，不開視窗、不連任何 session。
  python3 -I Tests/web/ask_float_check.py [--shots 資料夾]"""
import argparse, functools, html, http.server, json, os, re, subprocess, sys, tempfile, threading, shutil
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
ap = argparse.ArgumentParser(); ap.add_argument("--shots"); a = ap.parse_args()
WEB = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../Engine/windows/ShoWork.Win/Board/Web"))

JS = r"""
const P = new URLSearchParams(location.search), CASE = P.get("case"), fails = []; let n = 0, name = "";
const ok = (c, m) => { n++; if (!c) fails.push(name + "：" + m); }, wait = ms => new Promise(r => setTimeout(r, ms));
const posted = k => askPosted.filter(x => x.action === k), sends = () => askPosted.filter(x => x.action === "answer" || x.action === "permit");
const Q = (sid, id, o = {}) => ({ status: "需要你", sessionId: sid, askId: id, name: o.name || "測試 " + sid, ask: o.ask || "要怎麼做 " + id + "？", options: o.options || ["好，照做（建議）", "先不要", "改天", "取消"], ago: 2, ...o });
const up = (...team) => askUpdate({ team }), S = () => askState(), el = s => document.querySelector(s);
const ev = (t, type, o = {}) => t.dispatchEvent(new (type.startsWith("pointer") ? PointerEvent : type.startsWith("key") ? KeyboardEvent : MouseEvent)(type, { bubbles: true, cancelable: true, button: 0, detail: 1, ...o }));
const press = t => { ev(t, "pointerdown"); ev(t, "mousedown"); }, release = t => { ev(t, "pointerup"); ev(t, "click"); };
const tap = t => { press(t); release(t); };
const key = (k, o = {}, t = document.body) => ev(t, "keydown", { key: k, ...o });
const opt = k => document.querySelectorAll(".opt")[k];
async function fresh(t, ...qs) { name = t; document.activeElement.blur(); up(); await wait(1700); ok(!S().ghost && !S().undo && !S().visible.length && !S().sent.length, "上一個測試沒清乾淨 " + JSON.stringify(S())); up(...qs); await wait(560); askPosted.length = 0; }
async function checks() {
  await fresh("不搶鍵盤", Q("s1", "A")); ok(S().open && S().cur === "s1|a:A", "應該顯示"); ok(!S().armed, "跳出時不可收鍵盤");
  for (const k of ["1", "2", "Enter", "Escape"]) key(k); ok(!S().undo && S().open, "沒點過卡片，按鍵不可作答");
  tap(el(".sum").parentNode); ok(S().armed, "點卡片後才收鍵盤"); window.dispatchEvent(new Event("blur")); ok(!S().armed, "失焦要失效"); key("1"); ok(!S().undo, "失焦後數字不可作答");
  tap(el("#card")); key("1", { isComposing: true }); key("Enter", { keyCode: 229 }); key("1", { repeat: true }); key("1", { metaKey: true }); ok(!S().undo, "組字、重複、帶修飾鍵不可作答");
  document.dispatchEvent(new CompositionEvent("compositionend")); key("Enter"); ok(!S().undo, "組字剛結束的 Enter 不可作答"); await wait(200);
  key("2"); ok(S().undo === "s1|a:A", "點過卡片後數字可作答"); ok(!sends().length, "3 秒內還沒真的送"); ok(!S().armed, "送出後解除鍵盤");
  tap(el("[data-undo]")); ok(!S().undo && S().cur === "s1|a:A" && S().visible.length === 1, "復原"); await wait(3200); ok(!sends().length, "復原後不可送");

  await fresh("滑鼠作答", Q("s1", "A")); tap(opt(2)); ok(S().undo === "s1|a:A", "點選項"); ok(posted("askFocusBack").length === 1, "滑鼠答完還焦點"); await wait(3100);
  ok(sends().length === 1 && sends()[0].option === "改天" && sends()[0].askId === "A" && sends()[0].sessionId === "s1", "送一次、帶題目 id " + JSON.stringify(sends()));
  up(Q("s1", "A")); ok(!S().visible.length, "送出中不再顯示"); up(); ok(!S().sent.length, "題目拿掉＝送到");

  await fresh("換題 0.5 秒", Q("s1", "A"), Q("s2", "B")); tap(opt(0)); ok(S().cur === "s2|a:B", "接下一題"); tap(opt(0)); ok(S().visible.length === 1, "剛換題的點擊不算"); ok(S().undo === "s1|a:A", "沒有多送");
  key("1"); ok(S().undo === "s1|a:A", "剛換題按鍵不算"); press(opt(0)); await wait(560); release(opt(0)); ok(S().visible.length === 1, "按下那刻還沒過 0.5 秒也不算"); tap(opt(1)); ok(S().undo === "s2|a:B", "過了 0.5 秒可以"); ok(!sends().length, "按第二題時第一題不提早送"); await wait(3100); ok(sends().map(x => x.askId).join() === "A,B", "各自滿 3 秒、各一次 " + sends().map(x => x.askId));

  await fresh("按下後換題", Q("s1", "A"), Q("s2", "B")); const b0 = opt(0); press(b0); up(Q("s2", "B")); ev(b0, "pointerup"); ev(opt(0), "click"); await wait(50); ok(!S().undo, "按下到放開中間題目沒了，不可作答");
  await fresh("新題不換掉正在看的", Q("s2", "B")); const pn = pos(); up(Q("s1", "A"), Q("s2", "B"), Q("s3", "C")); ok(S().cur === "s2|a:B", "還是原本那題"); ok(pos() === pn, "新題進來選項不可移動"); ok(el(".nav").textContent.includes("1/3"), "顯示 1/3 " + el(".nav").textContent);
  tap(el('[data-nav="1"]')); ok(S().cur !== "s2|a:B" && S().locked, "換下一題並鎖住"); ok(S().armed, "自己按換題還是可用鍵盤"); key("1"); ok(!S().undo, "鎖住時按鍵不算");

  await fresh("看到一半被答掉", Q("s1", "A"), Q("s2", "B")); up(Q("s2", "B")); ok(S().ghost && (el("#over .st")?.textContent || "").includes("已經在別處"), "要明講"); ok(getComputedStyle(el(".opts")).pointerEvents === "none", "按鈕停用"); tap(el("#card")); key("1"); ok(!S().undo && !S().armed, "不可作答");
  await wait(1600); ok(S().cur === "s2|a:B" && S().locked, "自動換下一題並鎖住"); tap(opt(0)); ok(!S().undo, "換過去那一下不算");
  await fresh("打字中被答掉", Q("s1", "A"), Q("s2", "B")); const ta = el("textarea"); press(ta); ta.focus(); ta.value = "打到一半"; ev(ta, "input"); up(Q("s2", "B")); await wait(1700); ok(S().ghost && el("textarea") === ta && ta.value === "打到一半", "打字中不換題、字還在"); key("Enter", { metaKey: true }, ta); ok(!S().undo, "送不出去"); ta.blur(); await wait(60); ok(S().cur === "s2|a:B", "離開輸入框才換"); ok(el("textarea").value === "", "草稿不可跑到下一題");

  await fresh("草稿照題目", Q("s1", "A")); const t1 = el("textarea"); t1.value = "給 A 的話"; ev(t1, "input"); up(Q("s1", "A2")); await wait(1700); ok(S().cur === "s1|a:A2" && el("textarea").value === "", "同一個 session 換題，草稿不跟過去"); await wait(560); tap(opt(0)); await wait(3100); ok(sends().at(-1).free === "" && sends().at(-1).askId === "A2", "沒有帶到舊草稿");
  await fresh("補充框", Q("s1", "A")); const t2 = el("textarea"); press(t2); t2.focus(); t2.value = "中文"; ev(t2, "input"); key("Enter", {}, t2); ok(!S().undo, "Enter 是換行"); key("Enter", { metaKey: true, isComposing: true }, t2); ok(!S().undo, "組字中 ⌘Enter 不送"); key("1", {}, t2); ok(!S().undo, "打字框裡的數字是字"); up(Q("s1", "A"), Q("s9", "Z")); ok(el("textarea") === t2 && document.activeElement === t2, "新題進來不重畫輸入框"); key("Enter", { metaKey: true }, t2); ok(S().undo === "s1|a:A", "⌘Enter 送"); ok(!posted("askFocusBack").length, "鍵盤送的不把焦點還給終端機"); await wait(3100); ok(sends().length === 1 && sends()[0].free === "中文" && !sends()[0].option, "只送補充");

  await fresh("復原期間題目沒了", Q("s1", "A")); tap(opt(0)); up(); await wait(3200); ok(!sends().length && el("#over").textContent.includes("沒有送出"), "不送並明講 " + el("#over").textContent);
  await fresh("復原期間內容變了", Q("s1", "A")); tap(opt(0)); up(Q("s1", "A", { options: ["部署", "刪掉", "x", "y"] })); await wait(3200); ok(!sends().length, "選項變了不送"); ok(S().visible.length === 1, "題目放回來");
  await fresh("選項變了要鎖", Q("s1", "A")); tap(el("#card")); up(Q("s1", "A", { options: ["部署", "刪掉", "x", "y"] })); tap(opt(0)); key("1"); ok(!S().undo, "剛變的選項 0.5 秒內不算");
  for (const st of ["sending", "unsure"]) { await fresh("狀態 " + st, Q("s1", "A", { askState: st })); ok(!!el("#over .st"), "要顯示"); tap(el("#card")); key("1"); ev(opt(0), "pointerdown"); ev(opt(0), "click"); ok(!S().undo, "不可按"); }
  await fresh("沒送出要放回來", Q("s1", "A")); tap(opt(0)); await wait(3100); askResult("s1", "A", "「x」這題已經答過或已收掉，沒有送出"); ok(S().visible.length === 1 && (el("#over .st")?.textContent || "").includes("沒有送出"), "放回來並明講");
  await fresh("送出後沒下文", Q("s1", "A")); tap(opt(0)); await wait(3100); up(Q("s1", "A")); ok(!S().visible.length, "先不顯示"); up(Q("s1", "A", { askState: "unsure" })); ok(S().visible.length === 1, "變成沒確認到就放回來");

  await fresh("點標題", Q("s1", "A"), Q("s2", "B")); tap(el(".top .nm")); ok(posted("focus").length === 1 && posted("focus")[0].sessionId === "s1" && !S().open && !S().undo, "只跳、縮成一條"); ok(el("#strip").textContent.includes("需要你 · 測試 s1"), "條上寫誰 " + el("#strip").textContent); key("1"); key("Enter"); ok(!S().undo, "縮著時按鍵不算"); ok(document.body.classList.contains("mini"), "不消失");
  up(Q("s1", "A"), Q("s2", "B"), Q("s3", "C")); ok(!S().open && el("#strip").textContent.includes("共 3 題"), "新題不自己展開，只加題數"); tap(el("#strip")); ok(S().open && S().locked && !S().armed, "點條展開、鎖住、不收鍵盤"); tap(opt(0)); ok(!S().undo, "連點展開那一下不算");
  await fresh("點問題", Q("s1", "A")); if (!S().open) tap(el("#strip")); await wait(560); askPosted.length = 0; tap(el(".q")); ok(posted("focus").length === 1 && !S().undo, "點問題＝跳"); tap(el("#strip")); await wait(560);
  askPosted.length = 0; press(el("textarea")); release(el("textarea")); ok(!posted("focus").length && S().open, "點補充框不跳"); tap(el("[data-later]")); ok(!S().open && document.body.classList.contains("mini"), "稍後再答＝縮成一條"); askShow("s1"); ok(S().open && S().locked, "戰情列叫出");
  await fresh("拖動", Q("s1", "A")); ev(el(".top .nm"), "pointerdown", { screenX: 10, screenY: 10 }); ev(document, "pointermove", { screenX: 40, screenY: 30 }); ev(el(".top .nm"), "pointerup"); ev(el(".top .nm"), "click"); ok(posted("askDrag").map(x => x.phase).join() === "start,move,end" && !posted("focus").length, "拖動不算點"); ok(posted("askDrag")[1].dx === 30, "位移");
  await fresh("鍵盤觸發的 click", Q("s1", "A")); ev(opt(0), "pointerdown"); ev(opt(0), "click", { detail: 0 }); ok(!S().undo, "detail 0 不算"); ok([...document.querySelectorAll("button")].every(b => b.tabIndex === -1), "按鈕不拿焦點");
  await fresh("權限框", { status: "需要你", sessionId: "p1", name: "權限", ask: "要不要讓它執行 Bash", permit: { id: "P1", kind: "tool", tool: "Bash", summary: "ls" }, ago: 0 }); tap(opt(0)); up({ status: "需要你", sessionId: "p1", name: "權限", ask: "要不要讓它執行 Bash", permit: { id: "P2", kind: "tool", tool: "Bash", summary: "rm" }, ago: 0 }); await wait(3200); ok(!sends().length, "換了一張權限框，不可送到新的"); ok(S().cur === "p1|p:P2", "顯示新的那張");
  await fresh("版面", Q("s1", "A", { ask: "很長的問題".repeat(40), options: ["很長的選項".repeat(20), "b".repeat(120), "c", "d"], summary: "摘要".repeat(60) }));
  for (const w of [440, 240]) { askMax(w, 900); await wait(60); const c = el("#card"); ok(c.scrollWidth <= c.clientWidth, w + " 寬不可橫向裁字"); for (const x of c.querySelectorAll(".q,.opt,.sum,.nm")) ok(x.scrollWidth <= x.clientWidth + 1 || getComputedStyle(x).display === "inline", w + " 裁字 " + x.className); ok(JSON.parse(sized).h >= Math.min(c.scrollHeight, 900) - 2, "回報高度夠"); }
  askMax(440, 260); await wait(60); ok(el("#card").getBoundingClientRect().height <= 261 && el("#card").scrollHeight > 261 && getComputedStyle(el("#card")).overflowY === "auto", "矮視窗可以捲到全部");
  const bg = getComputedStyle(el("#card")).backgroundColor; ok(!/rgba/.test(bg), "不透明底 " + bg); up(); await wait(1700); ok(JSON.parse(sized).mode === "hidden" || S().undo, "沒題就收");
  await reviews();
}
/* Gavin5 複核（T1125041307）的反例 */
const pos = () => [...document.querySelectorAll(".opt")].map(o => { const r = o.getBoundingClientRect(), v = JSON.parse(sized); return [r.left, r.top - v.h, r.width, r.height].map(Math.round).join(); }).join(" ");      // 卡片貼右下：對視窗下緣的位置
async function reviews() {
  askMax(440, 900); await wait(560);
  await fresh("復原條不位移", Q("s1", "A"), Q("s2", "B"), Q("s3", "C")); await wait(100); const q1 = [Q("s2", "B"), Q("s3", "C")];
  tap(opt(0)); await wait(600); const p0 = pos(); ok(el("#over [data-undo]"), "有復原條"); await wait(2700); ok(!el("#over [data-undo]"), "復原條收掉"); ok(pos() === p0, "復原條收掉選項不可移動 " + p0 + " → " + pos()); up(...q1); await wait(100); ok(pos() === p0, "題目拿掉後也不移動");
  await fresh("提示不位移", Q("s1", "A")); const p1 = pos(); askResult("s1", "A", "「x」這題已經答過或已收掉，沒有送出"); await wait(60); ok(el("#over .st") && pos() === p1, "提示出現不可移動 " + p1 + " → " + pos()); await wait(4200); ok(pos() === p1, "提示收掉不可移動");
  up(Q("s1", "A", { askState: "sending" })); await wait(60); ok(pos() === p1, "狀態列出現不可移動");
  await fresh("版面一動就鎖", Q("s1", "A")); ok(!S().locked, "先沒鎖"); askMoved(); ok(S().locked, "原生端移了位置"); tap(opt(0)); ok(!S().undo, "位移後 0.5 秒內不算"); press(opt(0)); await wait(560); release(opt(0)); ok(!S().undo, "按下那刻還在鎖，放開也不算"); askMax(300, 900); tap(opt(0)); ok(!S().undo, "寬度變了也鎖"); await wait(560); press(opt(0)); askMoved(); release(opt(0)); ok(!S().undo, "按著的時候位移，放開不算"); await wait(560); tap(opt(0)); ok(S().undo === "s1|a:A", "過了就能按"); askMax(440, 900);
  await fresh("復原後要再點卡片", Q("s1", "A"), Q("s2", "B")); tap(opt(0)); await wait(600); tap(el("#card .sum").parentNode); ok(S().armed, "點過 B"); tap(el("[data-undo]")); ok(S().cur === "s1|a:A" && !S().armed, "復原就解除"); await wait(600); key("2"); key("Enter"); ok(!S().undo, "沒點過 A 的卡不作答"); tap(el("#card .sum").parentNode); key("2"); ok(S().undo === "s1|a:A", "點過才算");
  await fresh("凍結", Q("s1", "A")); tap(opt(0)); const until = Date.now() + 6000; while (Date.now() < until); await wait(80); ok(!sends().length && S().visible.length === 1 && (el("#over")?.textContent || "").includes("停住太久"), "凍結 6 秒醒來不送、放回 " + el("#over").textContent); key("1"); ok(!S().undo, "醒來不收鍵盤");
  await fresh("各自倒數", Q("s1", "A"), Q("s2", "B"), Q("s3", "C")); tap(opt(0)); await wait(700); tap(opt(1)); ok(document.querySelectorAll("#over [data-undo]").length === 2, "兩題各有復原"); ok(!sends().length, "第一題沒提早"); tap(document.querySelector('[data-undo="s1|a:A"]')); await wait(3200); ok(sends().map(x => x.askId + x.option).join() === "B先不要", "只復原那題，另一題照送 " + sends().map(x => x.askId));
  await fresh("草稿回來", Q("s1", "A")); const t = el("textarea"); t.value = "草稿"; ev(t, "input"); up(); await wait(1700); up(); up(Q("s1", "A")); await wait(50); ok(el("textarea").value === "草稿", "同一題回來草稿要在");
  await fresh("可以再按的說法", Q("s1", "A")); tap(opt(0)); await wait(3100); up(Q("s1", "A")); await wait(8200); ok(el("#over").textContent.includes("可以再按"), "claim 會收才說可以再按 " + el("#over").textContent); up(Q("s1", "A", { askState: "sending" })); ok(!el("#over").textContent.includes("可以再按") && el("#over").textContent.includes("正在送"), "送出中不可說可以再按"); up(Q("s1", "A", { askState: "unsure" })); ok(!el("#over").textContent.includes("可以再按"), "沒確認到也不可說");
  await fresh("重新載入恢復", Q("s1", "A")); askRestore(false); ok(document.body.classList.contains("mini"), "縮成一條要留著"); askRestore(true); ok(S().open, "展開也要留著"); tap(el("[data-later]")); ok(posted("askOpen").at(-1)?.open === false, "有告訴原生端"); askRestore(true);
  await fresh("標題兩行", Q("s1", "A", { name: "開發 · Orbit42", doing: "答案卡補修" }), Q("s2", "B", { name: "開發 · Orbit42", doing: "終端機浮起".repeat(12) })); ok(el(".top .nm").textContent === "開發 · Orbit42 · 答案卡補修", "要帶工作標題 " + el(".top .nm").textContent);
  tap(el('[data-nav="1"]')); const nm = el(".top .nm"); ok(nm.textContent.endsWith("終端機浮起") && nm.scrollWidth <= nm.clientWidth + 1 && el("#card").scrollWidth <= el("#card").clientWidth, "同職責同專案分得出來、展開整段看得到"); tap(el("[data-later]")); const sn = el("#strip .nm"); ok(sn.scrollWidth > sn.clientWidth && getComputedStyle(sn).textOverflow === "ellipsis" && el("#strip").getBoundingClientRect().width <= 440, "縮成一條才截"); tap(el("#strip")); ok(S().open, "點開看全"); await wait(560);
  up(Q("s1", "A", { name: "甲", doing: "甲" })); await wait(1700); ok(el(".top .nm").textContent === "甲", "一樣的不重複");
  await fresh("不可注入", Q("s1", "<img src=x onerror=window.xss=1>", { options: ["<img src=x onerror=window.xss=1>", "b"], name: "<b onmouseover=1>", ask: "<script>window.xss=1<\/script>" })); await wait(300); ok(window.xss === undefined && !el("#card img"), "字就是字");
}
async function shot() {
  askTheme(P.get("theme")); document.body.style.padding = "0"; askMax(+(P.get("w") || 440), 900);
  const long = { name: "Orbit42 開發 · Orbit42", summary: "答案卡移到最上層、點標題會跳過去、失焦就不收鍵盤", ask: "答案卡做了 4 件事：浮在所有終端機上面、點標題跳到那顆、縮成一條不擋輸入框、送出後 3 秒內可以復原。要裝進 Orbit42 並重開嗎？（重開會打斷你正在用的畫面）", options: ["好，跟 Hana5 那批一起裝，裝之前再問我一次（建議）", "先不要，我想看過深色和淺色兩版的放大圖再決定要不要裝", "只推到分支", "先停著，等終端機滑過浮起也做完再一起裝"] };
  const qs = { short: [Q("s1", "A", { name: "秘書 · Orbit42", ask: "要 push 嗎？", options: ["好，push（建議）", "先不要", "等我看過", "改天"] })], long: [Q("s1", "A", long)], three: [Q("s1", "A", { name: "秘書 · Orbit42", ask: "要 push 嗎？" }), Q("s2", "B"), Q("s3", "C")], unsure: [Q("s1", "A", { ...long, askState: "unsure" })] }[CASE.split("-")[0]];
  up(...qs); if (CASE.endsWith("strip")) tap(el("[data-later]")); if (CASE.endsWith("undo")) { await wait(560); tap(opt(0)); }
}
addEventListener("load", async () => {
  try { if (CASE === "check") await Promise.race([checks(), wait(200000).then(() => fails.push("跑太久，停在 " + name))]); else await shot(); } catch (e) { fails.push(name + " 例外 " + e.stack); }
  if (CASE === "check") fetch("/result", { method: "POST", body: JSON.stringify({ n, fails }) });
});
"""
tmp = tempfile.mkdtemp(prefix="askfloat-")
s = open(WEB + "/ask.html", encoding="utf-8").read()
assert "Content-Security-Policy" in s
s = re.sub(r'<meta http-equiv="Content-Security-Policy"[^>]*>', "", s)      # 測試頁要把結果送回來
open(tmp + "/ask.html", "w", encoding="utf-8").write(s + "<script>" + JS + "</script>")
got, done = [], threading.Event()


class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *x): pass

    def do_POST(self):
        got.append(self.rfile.read(int(self.headers["Content-Length"])).decode()); done.set(); self.send_response(204); self.end_headers()


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(H, directory=tmp)); threading.Thread(target=srv.serve_forever, daemon=True).start()
URL = f"http://127.0.0.1:{srv.server_port}/ask.html?"
BASE = [CHROME, "--headless=new", "--no-first-run", "--hide-scrollbars"]
p = subprocess.Popen(BASE + ["--remote-debugging-port=0", f"--user-data-dir={tmp}/r", "--window-size=700,1000", URL + "case=check"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
done.wait(220); p.terminate(); p.wait(20)
r = json.loads(got[0]) if got else {"n": 0, "fails": ["沒有結果（頁面沒跑完）"]}
print(f"答案卡浮層：{r['n']} 項，失敗 {len(r['fails'])}")
for x in r["fails"]: print("   ✗", x)
if a.shots:
    os.makedirs(a.shots, exist_ok=True)
    for th in ("dark", "light"):
        for c, w in (("short", 440), ("long", 440), ("long-narrow", 240), ("three", 440), ("short-strip", 440), ("three-strip", 440), ("three-undo", 440), ("unsure", 440)):
            subprocess.run(BASE + [f"--user-data-dir={tmp}/s", "--window-size=480,760", "--force-device-scale-factor=2", "--virtual-time-budget=1500", "--default-background-color=" + ("303034ff" if th == "dark" else "d8d8d8ff"),
                                   f"--screenshot={a.shots}/{th}-{c}.png", URL + f"case={c}&theme={th}&w={w}"], capture_output=True, timeout=60)
srv.shutdown(); shutil.rmtree(tmp, ignore_errors=True)
sys.exit(1 if r["fails"] or not r["n"] else 0)
