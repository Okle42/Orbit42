// 11-24 Keng「手機在看終端機時，Mac 這顆衛星的字縮成手機版、往中間靠，左右兩側空著；
// 左右加像警告標語的跑馬燈（參考：活動手環票帶），垂直上下跑；上面要有很酷的『手機端使用中』標語」
// 11-24 Keng「要符合深淺色模式：深色用白色、淺色用紅色」「只作動於電腦端，不影響手機版的顯示」
//
// 做法：不碰 index.html 的邏輯。手機在看時 fitPhone() 會把 .term 的 padding-left 設成置中留白；
// 這裡用 MutationObserver 看每個 .term 的 style，有留白就在左右空白處長出票帶，留白消失（手機離開）就收掉。
// 整層 pointer-events: none，不擋選字、捲動、點擊。手機（?mirror）整支不跑。
(() => {
  if (new URLSearchParams(location.search).has("mirror")) return;      // 手機版：完全不動
  const css = `
  .pb { position: absolute; top: 0; bottom: 0; pointer-events: none; z-index: 5; display: flex; gap: 6px; overflow: hidden; }
  .pb.l { left: 0; justify-content: flex-end; padding-right: 6px; }
  .pb.r { right: 0; justify-content: flex-start; padding-left: 6px; }
  :root { --pb-a: #ffffff; --pb-on: #0b0b0c; --pb-bg: #0d0d0f; }
  :root[data-theme="light"] { --pb-a: #d7261b; --pb-on: #ffffff; --pb-bg: #fbfbf9; }
  .pb .col { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
  /* 頂端標牌：LIVE 燈＋手機圖示＋直書「手機使用中」 */
  .pb .tag { flex: none; background: var(--pb-a); color: var(--pb-on); border-radius: 4px; padding: 7px 0 9px;
             display: flex; flex-direction: column; align-items: center; gap: 6px; position: relative;
             font: 800 11px/1 -apple-system, "PingFang TC", sans-serif; letter-spacing: .5px; }
  .pb .tag::after { content: ""; position: absolute; left: 0; right: 0; bottom: -5px; height: 3px;
             background: repeating-linear-gradient(90deg, var(--pb-a) 0 3px, transparent 3px 6px); }   /* 撕線 */
  .pb .tag .live { display: flex; flex-direction: column; align-items: center; gap: 3px; font-size: 7px; letter-spacing: 1px; }
  .pb .tag .live i { width: 6px; height: 6px; border-radius: 50%; background: var(--pb-on); animation: pbBlink 1s steps(2) infinite; }
  .pb .tag svg { width: 14px; height: 22px; }
  .pb .tag .big { writing-mode: vertical-rl; font-size: 15px; font-weight: 900; letter-spacing: 3px; }
  .pb .tag .sm { writing-mode: vertical-rl; font-size: 8px; letter-spacing: 2px; opacity: .75; }
  /* 票帶：打孔＋條碼＋直書標語，內容重複兩份、往上或往下無限捲 */
  .pb .band { flex: 1; min-height: 0; position: relative; overflow: hidden; border-radius: 3px; }
  .pb .band.a { background: var(--pb-a); color: var(--pb-on); }
  .pb .band.b { background: var(--pb-bg); color: var(--pb-a); box-shadow: inset 0 0 0 1.5px var(--pb-a); }
  .pb .band::before, .pb .band::after { content: ""; position: absolute; top: 0; bottom: 0; width: 4px; z-index: 1;
             background: radial-gradient(circle, var(--pb-bg) 1.3px, transparent 1.6px) 0 0 / 4px 9px repeat-y; }     /* 打孔 */
  .pb .band.b::before, .pb .band.b::after { background-image: radial-gradient(circle, var(--pb-a) 1.1px, transparent 1.4px); }
  .pb .band::before { left: 1px; } .pb .band::after { right: 1px; }
  .pb .strip { position: absolute; left: 0; right: 0; top: 0; display: flex; flex-direction: column; align-items: center;
             animation: pbUp var(--pb-dur, 18s) linear infinite; }
  .pb .band.down .strip { animation-name: pbDown; }
  .pb .unit { display: flex; flex-direction: column; align-items: center; gap: 12px; padding: 12px 0 0; }
  .pb .txt { writing-mode: vertical-rl; white-space: nowrap; font: 900 13px/1 "Arial Narrow", -apple-system, "PingFang TC", sans-serif;
             letter-spacing: 2px; text-transform: uppercase; }
  .pb .txt.zh { font-size: 12px; letter-spacing: 4px; }
  .pb .bar { width: 60%; height: 34px; background: repeating-linear-gradient(0deg, currentColor 0 1px, transparent 1px 3px, currentColor 3px 5px, transparent 5px 6px, currentColor 6px 7px, transparent 7px 10px); }
  .pb .hz { width: 100%; height: 22px; background: repeating-linear-gradient(-45deg, currentColor 0 5px, transparent 5px 10px); }
  .pb .no { writing-mode: vertical-rl; font: 700 8px/1 ui-monospace, Menlo, monospace; letter-spacing: 1px; opacity: .7; }
  /* 11-24 Keng「第四到第六條合成一條粗一點的警告帶、第七條放空、對面鏡像，不然太亂」：
     粗警告帶＝斜紋（會往上／下跑）＋正中間一塊直書標籤；最靠終端那條空著（.gap） */
  .pb .band.warn { background: repeating-linear-gradient(-45deg, var(--pb-a) 0 12px, var(--pb-bg) 12px 24px);
             background-size: 100% 67.88px; animation: pbHazUp 3s linear infinite; box-shadow: inset 0 0 0 1.5px var(--pb-a); }
  .pb .band.warn.down { animation-name: pbHazDown; }
  .pb .band.warn::before, .pb .band.warn::after { display: none; }
  .pb .band.warn .lab { position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%); z-index: 2;
             background: var(--pb-bg); color: var(--pb-a); box-shadow: 0 0 0 2px var(--pb-a), 0 0 0 6px var(--pb-bg);
             border-radius: 3px; padding: 14px 6px; display: flex; flex-direction: column; align-items: center; gap: 10px; }
  .pb .band.warn .lab .zh { writing-mode: vertical-rl; font: 900 20px/1 -apple-system, "PingFang TC", sans-serif; letter-spacing: 6px; }
  .pb .band.warn .lab .en { writing-mode: vertical-rl; font: 800 10px/1 "Arial Narrow", -apple-system, sans-serif; letter-spacing: 3px; }
  .pb .gap { flex: none; }
  @keyframes pbHazUp { to { background-position: 0 -67.88px; } }
  @keyframes pbHazDown { to { background-position: 0 67.88px; } }
  @keyframes pbUp { from { transform: translateY(0); } to { transform: translateY(-50%); } }
  @keyframes pbDown { from { transform: translateY(-50%); } to { transform: translateY(0); } }
  @keyframes pbBlink { 50% { opacity: .15; } }
  @media (prefers-reduced-motion: reduce) { .pb .strip, .pb .tag .live i { animation: none; } }
  `;
  const st = document.createElement("style"); st.textContent = css; document.head.appendChild(st);

  const phone = `<svg viewBox="0 0 16 24" fill="none" stroke="currentColor" stroke-width="1.6"><rect x="1.5" y="1" width="13" height="22" rx="3"/><path d="M6 3.6h4"/><circle cx="8" cy="19.6" r="1" fill="currentColor" stroke="none"/></svg>`;
  const unit = n => `<div class="unit">
      <div class="txt">Phone in use</div><div class="bar"></div>
      <div class="txt zh">手機使用中</div><div class="hz"></div>
      <div class="txt">Orbit42 · Live</div><div class="no">No.${n}</div>
      <div class="txt zh">勿動鍵盤</div><div class="bar"></div>
      <div class="txt">Mirror on</div><div class="hz"></div></div>`;
  // 起點錯開（負的 delay），一打開每條的字就不在同一高度
  const band = (kind, dir, n, dur) => `<div class="band ${kind} ${dir}" style="--pb-dur:${dur}s"><div class="strip" style="animation-delay:-${(n * 1.37) % dur}s">${unit(n)}${unit(n)}</div></div>`;
  const tag = `<div class="tag"><div class="live"><i></i>LIVE</div>${phone}<div class="big">手機使用中</div><div class="sm">PHONE ON</div></div>`;
  const BAND_W = 28, GAP = 6, MIN = BAND_W + GAP * 2;

  function side(cls, w, dir) {
    // 留白多寬就長幾條，把整片空白填滿；每條寬度平均分掉剩下的空間（約 28～40px）
    const n = Math.max(1, Math.min(14, Math.floor((w - GAP) / (BAND_W + GAP))));
    const bw = Math.min(40, Math.floor((w - GAP * (n + 1)) / n));
    const el = document.createElement("div"); el.className = "pb " + cls; el.style.width = w + "px";
    // 11-24 Keng：由外往內＝一般票帶…、粗警告帶（佔 3 條寬，頂端放標牌）、空一條；右邊鏡像（由內往外）。
    // 條數不夠時：粗警告帶吃掉「空的那條」以外全部
    const gapN = n >= 2 ? 1 : 0, warnN = n >= 5 ? 3 : n - gapN, regN = n - gapN - warnN;
    const warnW = warnN * bw + (warnN - 1) * GAP;
    const cols = [];                                   // 由外往內
    for (let i = 0; i < regN; i++) {
      const kind = i % 2 === 0 ? "a" : "b", d = i % 2 === 0 ? dir : (dir === "up" ? "down" : "up");
      cols.push(`<div class="col" style="width:${bw}px">${band(kind, d, 4200 + i * 17, 14 + (i * 7) % 11)}</div>`);
    }
    cols.push(`<div class="col" style="width:${warnW}px">${tag}<div class="band warn ${dir}"><div class="lab"><div class="zh">手機使用中</div><div class="en">PHONE IN USE</div></div></div></div>`);
    if (gapN) cols.push(`<div class="gap" style="width:${bw}px"></div>`);
    el.innerHTML = (cls === "l" ? cols : cols.reverse()).join(""); return el;
  }

  function sync(t) {
    const padL = parseFloat(t.style.paddingLeft) || 0;
    const sc = t.querySelector(".xterm-screen");
    const rightW = sc ? Math.floor(t.clientWidth - padL - sc.getBoundingClientRect().width) : 0;
    const key = padL >= MIN && rightW >= MIN ? `${Math.floor(padL)}|${rightW}` : "";
    if (t._pbKey === key) return;
    t._pbKey = key;
    t.querySelectorAll(":scope > .pb").forEach(x => x.remove());
    if (!key) return;
    t.appendChild(side("l", Math.floor(padL), "up"));
    t.appendChild(side("r", rightW, "down"));
  }

  const watch = t => { if (t._pbObs) return; t._pbObs = new MutationObserver(() => sync(t)); t._pbObs.observe(t, { attributes: true, attributeFilter: ["style"] }); sync(t); };
  const boot = () => {
    const box = document.getElementById("terms"); if (!box) return;
    box.querySelectorAll(":scope > .term").forEach(watch);
    new MutationObserver(ms => ms.forEach(m => m.addedNodes.forEach(n => n.classList?.contains("term") && watch(n)))).observe(box, { childList: true });
    new ResizeObserver(() => box.querySelectorAll(":scope > .term").forEach(t => { t._pbKey = null; sync(t); })).observe(box);
  };
  document.readyState === "loading" ? document.addEventListener("DOMContentLoaded", boot) : boot();
})();
