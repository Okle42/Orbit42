#!/usr/bin/env python3
"""You 對話框亮邊的自動檢查（假終端機內容＋無頭 Chrome，不開視窗）。
  python3 -I Tests/web/you_frame_check.py [--web Web] [--shots 資料夾] [--cpu]
--web 指到舊版的 Web 資料夾可以看原本的樣子（根因那一項會失敗）。"""
import argparse, functools, html, http.server, json, os, re, shutil, subprocess, sys, tempfile, threading
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
ap = argparse.ArgumentParser(); ap.add_argument("--web"); ap.add_argument("--shots"); ap.add_argument("--cpu", action="store_true")
a = ap.parse_args()
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
WEB = os.path.abspath(a.web or os.path.join(ROOT, "Web"))

JS = r"""
const E = "\x1b[", P = new URLSearchParams(location.search), CASE = P.get("case");
const enc = s => { const b = new TextEncoder().encode(s); let o = ""; for (const c of b) o += String.fromCharCode(c); return btoa(o); };
const LIGHT = P.get("theme") === "light";
const GRAY = LIGHT ? "38;2;175;175;175" : "38;2;80;80;80", TXT = LIGHT ? "38;2;0;0;0" : "38;2;255;255;255";
const go = (y, x) => `${E}${y + 1};${x + 1}H`;
const W = s => [...s].reduce((n, c) => n + (c.codePointAt(0) > 0x2e7f ? 2 : 1), 0);
let C, R;
/* 照 Claude Code 的送法只送「有變的」：You 標籤是灰色粗體，粗體結束只送 22，後面的框線不再重送灰色（假設，見回報） */
function you(y, lines, opt = {}) {
  const right = C - 3, w = Math.max(...lines.map(W)) + 4, l = right - w + 1, n = lines.length; let s = E + "0m";
  const vis = r => r >= (opt.min ?? 0) && r < (opt.max ?? R);
  if (vis(y)) s += `${go(y, right - 7)}${E}1m${E}${GRAY}mYou  ⬤ ${E}22m`; else s += `${E}${GRAY}m`;
  if (vis(y + 1)) s += `${go(y + 1, l)}╭${"─".repeat(w - 2)}╮`;
  lines.forEach((t, i) => { if (vis(y + 2 + i)) s += `${go(y + 2 + i, l)}│ ${E}${TXT}m${t}${" ".repeat(w - 4 - W(t))}${E}${GRAY}m │`; });
  if (vis(y + 2 + n)) s += `${go(y + 2 + n, l)}╰${"─".repeat(w - 2)}╯`;
  return { s: s + E + "0m", l, r: right, top: y + 1, bot: y + 2 + n };
}
const claudeBox = y => `${go(y, 1)}${E}91m⬤  Claude${E}0m${go(y + 1, 1)}${E}${GRAY}m╭${"─".repeat(C - 5)}╮${go(y + 2, 1)}│${go(y + 2, C - 3)}│${go(y + 3, 1)}╰${"─".repeat(C - 5)}╯${E}0m`;
const table = y => `${go(y, 2)}${E}${GRAY}m┌────┬────┐${go(y + 1, 2)}│ a  │ b  │${go(y + 2, 2)}└────┴────┘${E}0m`;
const input = y => `${go(y, 0)}${E}${GRAY}m╭${"─".repeat(C - 2)}╮${go(y + 1, 0)}│ >${go(y + 1, C - 1)}│${go(y + 2, 0)}╰${"─".repeat(C - 2)}╯${E}0m`;
const wait = ms => new Promise(r => setTimeout(r, ms));
let term, t, fails = [], n = 0;
const write = s => new Promise(r => { window.orbitData("x", enc(s)); term.write("", r); });
const cell = (y, x) => term.buffer.active.getLine(term.buffer.active.viewportY + y).getCell(x);
const fg = (y, x) => { const c = cell(y, x); return c.isFgRGB() ? "#" + c.getFgColor().toString(16).padStart(6, "0") : c.isFgDefault() ? "default" : "p" + c.getFgColor(); };
const isLight = () => document.documentElement.dataset.theme === "light";
const HOT = () => isLight() ? "#d7261b" : "#4fc36a", COLD = () => isLight() ? "#424242" : "#505050";
let where = "";
const ok = (c, m) => { n++; if (!c) fails.push(m); };
const rgb = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
const dist = h => { const v = rgb(h), u = rgb(HOT()); return v.reduce((s, x, i) => s + Math.abs(x - u[i]), 0); };
function frame(f, dir, name, o = {}) {
  const y0 = Math.max(f.top, o.min ?? 0), y1 = Math.min(f.bot, (o.max ?? R) - 1), seen = y => y >= y0 && y <= y1;
  const edge = dir > 0 ? f.top : f.bot, other = dir > 0 ? f.bot : f.top;
  for (const [y, want] of [[edge, HOT()], [other, COLD()]]) {
    if (!seen(y)) continue;
    let bad = null; for (let x = f.l; x <= f.r && !bad; x++) if (fg(y, x) !== want) bad = `第 ${y} 行第 ${x} 格 ${fg(y, x)}≠${want}`;
    ok(!bad, `${name}：${bad}`);
  }
  let last = -1;
  for (let y = dir > 0 ? y0 : y1; seen(y); y += dir) {
    const A = fg(y, f.l), B = fg(y, f.r);
    ok(A === B && A[0] === "#", `${name}：第 ${y} 行左右 ${A} ${B}`); if (A[0] !== "#") continue;
    const d = dist(A); ok(d >= last - 16, `${name}：第 ${y} 行沒有漸收`); last = d;
  }
  if (!seen(edge)) ok(fg(dir > 0 ? y0 : y1, f.r) === COLD(), `${name}：亮邊在畫面外應該全灰，實際 ${fg(dir > 0 ? y0 : y1, f.r)}`);
}
/* 像素檢查：在 xterm 畫完的同一刻抓 WebGL 畫面 */
const grab = () => new Promise(r => { const d = term.onRender(() => { d.dispose(); const gl = [...t.el.querySelectorAll(".xterm-screen canvas")].sort((a, b) => b.width * b.height - a.width * a.height).find(c => c.getContext("webgl2"));
  const cv = document.createElement("canvas"); cv.width = gl.width; cv.height = gl.height; const g = cv.getContext("2d"); g.fillStyle = LIGHT ? "#fbfbf9" : "#0d0d0f"; g.fillRect(0, 0, cv.width, cv.height); g.drawImage(gl, 0, 0); r(g); }); term.refresh(0, R - 1); });
async function pixels(f, dir, name, o = {}) {
  where = name;
  const g = await grab(), D = term._core._renderService.dimensions.device.cell, cw = D.width, ch = D.height;
  const y0 = Math.max(f.top, o.min ?? 0), y1 = Math.min(f.bot, (o.max ?? R) - 1), edge = dir > 0 ? f.top : f.bot;
  const s0 = Math.max(y0, f.top + 1), s1 = Math.min(y1, f.bot - 1); if (s1 < s0) return;
  const bgc = LIGHT ? [251, 251, 249] : [13, 13, 15], X = Math.min(cw - 1, Math.round(0.5 * cw + 0.5) - 1);
  for (const x of [f.l, f.r]) {
    const H = (s1 - s0 + 1) * ch, im = g.getImageData(x * cw, s0 * ch, cw, H).data, at = (r, q) => [0, 1, 2].map(k => im[(r * cw + q) * 4 + k]), v = [];
    for (let r = 0; r < H; r++) {
      const mask = []; for (let q = 0; q < cw; q++) if (Math.max(...at(r, q).map((c, k) => Math.abs(c - bgc[k]))) > 24) mask.push(q);
      ok(mask.length > 0 && mask.length <= 3 * devicePixelRatio && mask[mask.length - 1] - mask[0] === mask.length - 1, `${name}：第 ${r} 像素斷線或雙線 ${mask}`); v.push(at(r, X));
    }
    if (dir < 0) v.reverse();
    const far = (a, h) => Math.max(...rgb(h).map((c, i) => Math.abs(c - a[i]))), hasEdge = edge >= y0 && edge <= y1;
    if (hasEdge) ok(far(v[0], HOT()) <= 14, `${name}：側邊開頭沒接上亮邊 ${v[0]}`); else ok(v.every(a => far(a, COLD()) <= 14), `${name}：亮邊在畫面外應該全灰`);
    if (s1 - s0 >= 2 || (f.top >= y0 && f.bot <= y1)) ok(far(v[v.length - 1], COLD()) <= 14, `${name}：側邊結尾沒收成灰 ${v[v.length - 1]}`);
    const step = Math.max(0, ...v.slice(1).map((a, i) => Math.max(...a.map((c, k) => Math.abs(c - v[i][k]))))); ok(step <= 300 / ch, `${name}：側邊有一階 ${step}`); maxStep = Math.max(maxStep, step);
    ok(v.slice(1).every((a, i) => far(a, HOT()) >= far(v[i], HOT()) - 2), `${name}：側邊不是單調漸收`);
  }
}
let maxStep = 0;
const wheel = (dy, dx = 0) => t.el.querySelector(".xterm-screen").dispatchEvent(new WheelEvent("wheel", { bubbles: true, cancelable: true, deltaY: dy, deltaX: dx, deltaMode: 1 }));
const clear = () => write(`${E}0m${E}2J`);
async function both(f, name, o) { for (const d of [1, -1]) { wheel(3 * d); const nm = name + (d > 0 ? "・下捲" : "・上捲"); frame(f, d, nm, o); await pixels(f, d, nm, o); } wheel(3); }
async function checks() {
  let f;
  await write(`${E}?1049h${E}?1003h${E}?1006h`);
  await clear(); f = you(2, ["2"]); await write(f.s);
  ok(fg(f.top, f.l) !== "default", "根因：粗體結束後的框線變成預設色"); frame(f, 1, "預設"); await both(f, "短文");
  wheel(-1, 9); frame(f, 1, "橫向滑動不換邊");
  await clear(); f = you(3, ["第一行中文", "second line", "[Pasted text +12 lines]", "最後"]); await write(f.s); await both(f, "多行");
  await clear(); f = you(1, Array.from({ length: R - 8 }, (_, i) => "長文第 " + i + " 行 " + "字".repeat(12))); await write(f.s); await both(f, "長文");
  await clear(); f = you(2, ["╭──────╮", "│ code │", "╰──────╯"]); await write(f.s); const in0 = fg(f.top + 1, f.l + 2); await both(f, "框裡有框");
  for (let y = f.top + 1; y < f.bot; y++) ok(fg(y, f.l + 2) === in0 && in0 === (LIGHT ? "#1a1a1a" : "#4fc36a"), "框裡的小框被改色 " + fg(y, f.l + 2));
  await clear(); const fs = [you(0, ["一"]), you(6, ["two two"]), you(12, ["三", "三"])];
  await write(fs.map(x => x.s).join("") + claudeBox(18) + table(23) + input(27));
  const others = () => [[19, 1], [19, 9], [20, 1], [20, C - 3], [21, 5], [23, 2], [24, 2], [25, 7], [27, 0], [28, 0], [28, C - 1], [29, 9]].map(([y, x]) => fg(y, x)).join();
  const o0 = others(); ok(!o0.includes(HOT()), "別的框是亮色 " + o0);
  for (const d of [3, -3]) { wheel(d); for (const x of fs) { frame(x, Math.sign(d), "多框"); await pixels(x, Math.sign(d), "多框"); } ok(others() === o0, "別的框被改色"); } wheel(3);
  for (const [name, y, k, o] of [["標籤切掉", -1, 3, {}], ["上邊切掉", -2, 3, {}], ["只剩下邊", -4, 2, {}], ["標題列下標籤切掉", 0, 3, { min: 1 }], ["標題列下上邊切掉", -1, 3, { min: 1 }]]) {
    await clear(); f = you(y, ["a", "b", "c"].slice(0, k), o); await write((o.min ? go(0, 0) + "> 標題" : "") + f.s); await both(f, name, o);
  }
  await clear(); f = you(R - 8, ["a", "b", "c", "d", "e", "f"], { max: R - 4 }); await write(f.s + input(R - 3)); await both(f, "下緣切掉", { max: R - 4 });
  await clear(); f = you(-5, Array.from({ length: R + 10 }, () => "滿版")); await write(f.s); await both(f, "上下都切掉");
  await clear(); f = you(6, ["捲動", "區"]); await write(f.s); await write(`${E}1;${R - 4}r${E}2S${E}r`); f.top -= 2; f.bot -= 2; await both(f, "捲動區往上 2 行");
  await clear(); f = you(4, ["殘留"]); await write(f.s); await write(`${go(4, 0)}${E}2K`); ok(fg(f.top, f.l) === COLD(), "標籤不見了要還原成灰 " + fg(f.top, f.l));
  const th = document.documentElement.dataset.theme;
  await clear(); f = you(4, ["切換"]); await write(f.s); window.orbitTheme(th === "dark" ? "light" : "dark"); frame(f, 1, "切深淺即時換"); window.orbitTheme(th); frame(f, 1, "切回來"); await pixels(f, 1, "切回來");
  await write(""); await wait(50); frame(f, 1, "切過去再切回來、重上色後");
  await recolors(); await clear(); await write(f.s);
  t.term.clearTextureAtlas(); await pixels(f, 1, "清字形貼圖後"); const fs0 = term.options.fontSize; term.options.fontSize = fs0 - 4; await wait(200); await pixels(f, 1, "縮放後"); term.options.fontSize = fs0; await wait(200); await pixels(f, 1, "縮放回來");
  const txt0 = term.buffer.active.getLine(term.buffer.active.viewportY + f.top + 1).translateToString(); ok(txt0.includes("│ 切換 │"), "選字複製的內容不可變 " + txt0);
  ok(!t.el.querySelector(".youSide"), "不可有疊層");
  window.orbitReset("x"); await write(`${E}?1049h${E}?1003h`); t.paintYou(); ok(fg(f.top, f.l) === "default", "reset 後不可殘留");
  await clear(); await write(`${go(0, 0)}${E}2mhint${E}22mX${E}${GRAY}m${E}1mB${E}22mY${E}2mh${E}22mZ${E}0m`);      // 單獨的淡化提示字（原本 22 那條規則要保住的）
  if (th === "dark") { ok(fg(0, 0) === "#96969b", "提示字要灰 " + fg(0, 0)); ok(fg(0, 4) === "default", "提示字結束要還原 " + fg(0, 4)); }
  ok(fg(0, 6) === COLD(), "粗體結束不可清字色 " + fg(0, 6)); ok(fg(0, 8) === COLD(), "提示字結束要還原成原本的字色 " + fg(0, 8));
  ok(!cell(0, 6).isBold() && !cell(0, 8).isDim(), "22 要真的結束粗體與淡化");
  await write(`${E}?1003l${E}?1049l`); await clear(); f = you(3, ["一般模式"]); await write(f.s); await both(f, "一般模式");
}
// 切深淺：已經畫上去、程式不重送的字也要換色（Keng：切深色後 bypass permissions 還是紅字）
async function recolors() {
  const th = document.documentElement.dataset.theme, other = th === "dark" ? "light" : "dark", flip = async n => { window.orbitTheme(n); await write(""); await wait(30); };
  const RED = { light: "#c4211a", dark: "#ffffff" }, bgc = (y, x) => "#" + cell(y, x).getBgColor().toString(16).padStart(6, "0");
  const red = `${E}38;2;255;107;128m▸▸ bypass permissions on${E}39m`;
  await flip("light"); await clear();
  await write(`${go(1, 0)}${red}${go(2, 0)}${E}48;2;180;20;20mX${E}49m${go(3, 0)}${E}38;2;120;120;120mG${E}38;2;0;0;0mK${E}0m${go(4, 0)}${E}2mhint${E}22mN${E}31mP${E}0m${go(5, 0)}${E}38;2;255;107;128m`);
  ok(fg(1, 3) === RED.light, "淺色先要是紅 " + fg(1, 3)); const g0 = fg(3, 0);
  await flip("dark"); await write("續");      // 切之前就設好的字色，切完才打的字
  ok(fg(1, 3) === RED.dark && fg(1, 23) === RED.dark, "切深色後還是紅字 " + fg(1, 3)); ok(bgc(2, 0) === "#2e2e30", "紅底沒換 " + bgc(2, 0));
  const G = parseInt(fg(3, 0).slice(1, 3), 16); ok(Math.abs(G - 120) <= 3, "灰字差太多 " + fg(3, 0)); ok(fg(3, 1) === "#4fc36a", "黑字落在深底 " + fg(3, 1));
  ok(fg(4, 0) === "#96969b" && cell(4, 0).isDim(), "提示字沒換灰 " + fg(4, 0)); ok(fg(4, 4) === "default", "預設字不可動 " + fg(4, 4)); ok(fg(4, 5) === "p1", "色票色不可動 " + fg(4, 5));
  ok(fg(5, 0) === RED.dark, "切完接著打的字還是舊色 " + fg(5, 0));
  await flip("light"); ok(fg(1, 3) === RED.light && fg(5, 0) === RED.light, "切回淺色要變回紅 " + fg(1, 3)); ok(fg(3, 0) === g0, "灰字來回要一樣 " + fg(3, 0)); ok(fg(4, 0) === "default" && cell(4, 0).isDim(), "提示字來回 " + fg(4, 0));
  for (let i = 0; i < 6; i++) window.orbitTheme(i % 2 ? "light" : "dark"); await flip("dark"); ok(fg(1, 3) === RED.dark, "連切 " + fg(1, 3));
  // 還沒畫完就切：排隊中的輸出也要換
  await flip("light"); await clear(); window.orbitData("x", enc(go(1, 0) + red)); window.orbitTheme("dark"); window.orbitData("x", enc(go(2, 0) + red)); await write(""); await wait(30);
  ok(fg(1, 3) === RED.dark && fg(2, 3) === RED.dark, "排隊中的輸出 " + fg(1, 3) + fg(2, 3));
  // 捲動紀錄與另一個畫面
  await flip("light"); await write(`${E}0m${E}?1049l`); await clear(); await write(go(0, 0) + red + "\r\n".repeat(R + 20)); await write(`${E}?1049h`); await flip("dark");
  const nb = term.buffer.normal; let hits = 0, old = 0; for (let y = 0; y < nb.length; y++) { const c = nb.getLine(y).getCell(3); if (c.getChars() === "b" && c.isFgRGB()) { hits++; if (c.getFgColor() !== 0xffffff) old++; } }
  ok(hits > 0 && !old, `捲動紀錄 ${hits} ${old}`);
  const big = "一般 text ".repeat(6) + "\r\n"; await write(`${E}?1049l` + (E + "38;2;90;90;90m" + big).repeat(6000)); const t0 = performance.now(); await flip("light"); window.__recolorMs = Math.round(performance.now() - t0);
  await write(`${E}0m${E}3J${E}?1049h${E}?1003h${E}?1006h`); await flip(th);
}
async function shot() {
  await write(`${E}?1049h${E}?1003h`); await clear();
  let s = "";
  if (CASE === "short") s = you(1, ["2"]).s + you(7, ["push"]).s;
  if (CASE === "long") s = you(1, ["再長一點", "湊到十行", "第一行：把框線固定成同一個樣子", "second line", "[Pasted text +12 lines]", "第四行", "第五行", "最後一行"]).s;
  if (CASE === "multi") s = you(0, ["2"]).s + claudeBox(5) + you(10, ["push", "好"]).s + you(16, ["再一個"]).s + table(21);
  if (CASE === "cut") { await write(you(10, ["2"]).s); s = you(10, ["2"]).s + you(-2, ["上緣切掉", "bbb", "ccc"]).s + you(R - 7, ["下緣切掉", "b", "c", "d"], { max: R - 3 }).s + input(R - 3); }
  await write(s); wheel(P.get("dir") === "up" ? -3 : 3); await wait(300);
}
async function cpu() {
  const out = window.__cpu = {}, N = 3000; await write(`${E}?1049h${E}?1003h`);
  for (const mode of ["none", "box"]) {
    await clear(); if (mode === "box") await write(you(2, ["2"]).s + you(8, ["長", "文"]).s);
    const c = performance.now(); for (let i = 0; i < N; i++) await write(`${go(20, 2)}${E}38;2;200;200;200m串流輸出 ${i} ${"x".repeat(60)}${E}0m`);
    out[mode + "_us"] = +((performance.now() - c) / N * 1000).toFixed(1);
    if (t.paintYou) { const c2 = performance.now(); for (let i = 0; i < 5000; i++) t.paintYou(); out[mode + "_scan_us"] = +((performance.now() - c2) / 5).toFixed(1); }
  }
}
addEventListener("load", async () => {
  try {
    await wait(300); window.orbitData("x", ""); t = window.__terms.get("x"); term = t.term; t.el.classList.add("on"); document.getElementById("panel").classList.add("on");
    await wait(600); term.resize(90, 34); C = term.cols; R = term.rows; await wait(200);
    if (CASE === "check") await Promise.race([checks(), wait(70000).then(() => fails.push("跑太久，停在：" + where))]); else if (CASE === "cpu") await cpu(); else await shot();
  } catch (e) { fails.push("例外 " + e.stack); }
  const d = document.createElement("pre"); d.id = "RESULT"; d.style.display = "none"; d.textContent = JSON.stringify({ n, fails, maxStep, recolorMs: window.__recolorMs, cpu: window.__cpu }); document.body.append(d);
  fetch("/result", { method: "POST", body: d.textContent });
});
"""

tmp = tempfile.mkdtemp(prefix="youframe-")
site = os.path.join(tmp, "web"); shutil.copytree(WEB, site)
s = open(site + "/index.html", encoding="utf-8").read(); k = "\nwindow.orbitTheme(themeName);"
assert s.count(k) == 1
open(site + "/index.html", "w", encoding="utf-8").write(s.replace(k, "\nwindow.__terms = terms;" + k) + "<script type=module>" + JS + "</script>")


got, done = [], threading.Event()


class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *x): pass

    def do_POST(self):
        got.append(self.rfile.read(int(self.headers["Content-Length"])).decode()); done.set(); self.send_response(204); self.end_headers()


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(H, directory=site)); threading.Thread(target=srv.serve_forever, daemon=True).start()


def chrome(q, dpr, *extra, budget="--virtual-time-budget=20000"):
    try:
        return subprocess.run([CHROME, "--headless=new", "--no-first-run", "--hide-scrollbars", f"--user-data-dir={tmp}/p", "--window-size=1000,760",
                               f"--force-device-scale-factor={dpr}", budget, *extra, f"http://127.0.0.1:{srv.server_port}/index.html?term&{q}"],
                              capture_output=True, text=True, timeout=90).stdout
    except subprocess.TimeoutExpired:
        return ""


def result(q, dpr):      # 真時間跑，頁面跑完自己把結果送回來（抓畫面、量時間都不能用虛擬時間）
    got.clear(); done.clear()
    p = subprocess.Popen([CHROME, "--headless=new", "--no-first-run", "--remote-debugging-port=0", f"--user-data-dir={tmp}/r", "--window-size=1000,760", f"--force-device-scale-factor={dpr}",
                          f"http://127.0.0.1:{srv.server_port}/index.html?term&{q}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    done.wait(90); p.terminate(); p.wait(20)
    return json.loads(got[0]) if got else {"n": 0, "fails": ["沒有結果（頁面沒跑完）"]}


bad = 0
for theme in ("dark", "light"):
    for dpr in (1, 2):
        r = result(f"theme={theme}&case=check", dpr); bad += len(r["fails"]) + (r["n"] == 0)
        print(f"{theme} {dpr}x：{r['n']} 項，失敗 {len(r['fails'])}，側邊相鄰像素最大差 {r.get('maxStep')}，重上色含等待 {r.get('recolorMs')}ms")
        for x in r["fails"][:12]: print("   ✗", x)
if a.cpu: print("CPU（微秒；*_us＝每次寫入到處理完、*_scan_us＝掃一次）", result("theme=dark&case=cpu", 2).get("cpu"))
if a.shots:
    os.makedirs(a.shots, exist_ok=True)
    for th in ("dark", "light"):
        for c in ("short", "long", "multi", "cut"):
            for d in ("down", "up"): chrome(f"theme={th}&case={c}&dir={d}", 2, "--default-background-color=" + ("0d0d0fff" if th == "dark" else "fbfbf9ff"), "--default-background-color=" + ("0d0d0fff" if th == "dark" else "fbfbf9ff"), f"--screenshot={a.shots}/{th}-{c}-{d}.png")
srv.shutdown(); shutil.rmtree(tmp, ignore_errors=True)
sys.exit(1 if bad else 0)
