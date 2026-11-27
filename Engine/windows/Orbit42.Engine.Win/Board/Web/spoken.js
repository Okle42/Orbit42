/* 11-28 Keng「那語音播報先做口語改寫」：球體播報送進 TTS 前，把「寫給眼睛看」的卡片摘要改成「像人在講」的一句話。
   規則改寫：離線、零延遲，Mac（SphereWebScene）和 Windows（SphereHost）共用這一份。
   - Spoken.clean(s)：念出來會怪的拿掉或換說法（單號、commit 雜湊、路徑、網址、英文識別字長串、括號註解、｜：→ 等符號、session id；時間、日期、百分比改口語）
   - Spoken.card(kind, f)：看板狀態一變的那句播報（待審／完成／需要你／卡住）照人講話的句型組
   - Spoken.say(s)：任何一句播報的最後一道（clean＋在子句邊界收短，不留「⋯」）
   字幕顯示的就是改寫後這句（字幕跟聲音同一句，不能回到 11-23「語音跟字幕對不上」）。
   單元測試：Tests/Orbit42Tests/SpokenRewriteTests.swift（JavaScriptCore 直接跑這個檔）。 */
(function (root) {
  "use strict";
  const DIG = "零一二三四五六七八九";
  // 0–999 的中文數字（時間、日期、百分比用；一般數量交給 TTS 自己念）
  function zh(n) {
    n = Math.floor(n);
    if (n < 10) return DIG[n];
    if (n < 20) return "十" + (n % 10 ? DIG[n % 10] : "");
    if (n < 100) return DIG[Math.floor(n / 10)] + "十" + (n % 10 ? DIG[n % 10] : "");
    if (n < 1000) {
      const h = Math.floor(n / 100), r = n % 100;
      return DIG[h] + "百" + (r === 0 ? "" : r < 10 ? "零" + DIG[r] : r < 20 ? "一" + zh(r) : zh(r));
    }
    return String(n);
  }
  function clock(h, m) {
    h = +h; m = +m;
    const hh = h === 2 ? "兩" : zh(h);
    return hh + "點" + (m === 0 ? "" : m < 10 ? "零" + zh(m) + "分" : zh(m) + "分");
  }

  const CJK = "\\u3400-\\u9fff\\uf900-\\ufaff";
  const reCJKspace = new RegExp(`([${CJK}，。！？、；」』）])\\s+(?=[${CJK}，。！？、；「『（])`, "g");

  // 英文識別字長串：有底線、點接字母（檔名、a.b）、::、駝峰兩段以上、太長 ⇒ 念出來沒意義
  function isIdent(tok) {
    if (/^--?[a-z]/i.test(tok)) return true;                       // 指令參數 --status
    if (tok.includes("_") || tok.includes("::") || /\(\)$/.test(tok)) return true;
    if (/[A-Za-z0-9]\.[A-Za-z]/.test(tok)) return true;            // SphereAudio.swift、window.karaToast
    if (tok.length >= 18) return true;
    const humps = (tok.match(/[a-z][A-Z]/g) || []).length;
    return humps >= 2;                                              // SphereWebScene；GitHub、OpenJarvis 只有一段，留著
  }

  function clean(input) {
    let s = String(input == null ? "" : input);
    s = s.replace(/```[\s\S]*?```/g, " ")                           // 程式碼區塊整段不念
      .replace(/`([^`]*)`/g, "$1")
      .replace(/\*\*|__|[#*>]/g, "");
    s = s.replace(/放行[！!]/g, "放行");                                // 「放行！單號」是指令，念成句尾的驚嘆聽起來怪
    s = s.replace(/https?:\/\/\S+/gi, " ")                          // 網址
      .replace(/(^|[\s「『（(：:，,])(?:~|\.{1,2})?\/[^\s，。！？、；：「」『』（）()]*/g, "$1 ")   // 路徑 ~/.claude/x、/Users/…、./a/b（含中文檔名）
      .replace(/(^|[^\w/])[\w.\-]+(?:\/[^\s，。！？、；：「」『』（）()/]+){2,}\/?/g, "$1 ")   // Engine/Sources/Orbit42App（相對路徑，兩層以上）
      .replace(/(^|[^\w/])[\w.\-]+\/[\w.\-]*\.[A-Za-z]{1,6}\b/g, "$1 ")   // board/history.jsonl（一層＋副檔名；Cartesia/Eleven 這種不算）
      .replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, " ")   // session id
      .replace(/(?:派工)?(?:單號|單)\s*[:：]?\s*T\d{6,}/g, " ")        // 單號 T1128035638
      .replace(/\bT\d{6,}\b/g, " ");
    // 括號註解整段不念（全形、半形；含裡面已被拿掉的單號、雜湊）
    for (let i = 0; i < 3; i++) s = s.replace(/（[^（）]*）|\([^()]*\)|【[^【】]*】|\[[^\[\]]*\]/g, " ");
    s = s.replace(/[（）()【】\[\]]/g, " ");                          // 被截斷、沒配對的括號
    // commit 雜湊（7–40 位十六進位、字母數字都有）、放行碼這類大寫英數混合短碼
    const HASH = "\\b(?=[0-9a-f]*\\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\\b";
    s = s.replace(new RegExp(`(^|[，。、；：,;:]\\s*)(?:commit|雜湊)\\s*${HASH}`, "gi"), "$1 ")   // 「，commit 4a6ac92」整段不念（落單的 commit 聽起來像斷句）
      .replace(new RegExp(`(?:commit|雜湊)?\\s*${HASH}`, "gi"), (m) => /^\s*commit/i.test(m) ? " commit " : " ");
    s = s.replace(/\b(?=[A-Z0-9]*\d)(?=[A-Z0-9]*[A-Z])[A-Z0-9]{5,6}\b/g, " ");
    // 英文識別字長串
    s = s.replace(/[A-Za-z_\-][\w.\-:]*(?:\(\))?/g, (tok) => isIdent(tok) ? " " : tok);
    // 時間、日期、百分比 → 口語
    s = s.replace(/(^|[^\d:])([01]?\d|2[0-3]):([0-5]\d)(?![\d:])/g, (m, p, h, mm) => p + clock(h, mm));
    s = s.replace(/(^|[^\d\-/])(0?[1-9]|1[0-2])[-/](0?[1-9]|[12]\d|3[01])(?![\d\-/])(?=\s*(?:[^\d\s]|$))/g,
      (m, p, mo, d) => /^[0-9]{1,2}$/.test(mo) && (mo.length === 2 || d.length === 2) ? `${p}${zh(+mo)}月${zh(+d)}號` : m);
    s = s.replace(/(\d+(?:\.\d+)?)\s*[%％]/g, (m, n) => "百分之" + (/^\d+$/.test(n) && +n <= 999 ? zh(+n) : n));
    // 符號 → 停頓或口語
    s = s.replace(/\s*(?:→|⇒|->|=>|｜|\|)\s*/g, "，")
      .replace(/(\d)\s*[~～]\s*(\d)/g, "$1到$2")
      .replace(/([^\d\s])\s*[：:]\s*/g, "$1，")
      .replace(/\s*[；;]\s*/g, "，")
      .replace(/\s*[／/]\s*/g, "或")
      .replace(/\s*[＋+]\s*/g, "加")
      .replace(/\s*&\s*/g, "和")
      .replace(/[「」『』“”"‘’⋯…~～=<>{}\\^·・•]/g, " ");
    // 收拾：空白、重複標點、開頭標點、「或」「加」落單
    s = s.replace(/\s+/g, " ").trim()
      .replace(reCJKspace, "$1").replace(reCJKspace, "$1")
      .replace(/\s+([，。！？、])/g, "$1")
      .replace(/([，。！？、])\s+/g, "$1")
      .replace(/(^|[，。！？、])(?:或|加)+(?=[，。！？、]|$)/g, "$1")
      .replace(/[，、]{2,}/g, "，")
      .replace(/[，、]+([。！？])/g, "$1")
      .replace(/([。！？])[，、。]+/g, "$1")
      .replace(/^[，。！？、\s]+/, "")
      .replace(/[，、\s]+$/, "");
    return s;
  }

  // 收短：在句號／逗號這種念起來自然的地方斷，不留「⋯」（「⋯」念不出來，聽起來像話沒講完）
  function shorten(s, n) {
    s = String(s || "");
    const chars = Array.from(s);
    if (chars.length <= n) return s;
    const head = chars.slice(0, n + 1).join("");
    let cut = -1;
    for (const ch of "。！？") cut = Math.max(cut, head.lastIndexOf(ch));
    if (cut >= Math.floor(n * 0.4)) return head.slice(0, cut + 1);
    let soft = -1;
    for (const ch of "，、") soft = Math.max(soft, head.lastIndexOf(ch));
    if (soft >= Math.floor(n * 0.4)) return head.slice(0, soft) + "。";
    let k = n;                                   // 硬切：不切在英文字、數字中間（「Carte。」）
    while (k > Math.floor(n * 0.4) && /[A-Za-z0-9]/.test(chars[k - 1]) && /[A-Za-z0-9]/.test(chars[k] || "")) k--;
    if (k <= Math.floor(n * 0.4)) k = n;
    return chars.slice(0, k).join("").replace(/[\s，、]+$/, "") + "。";
  }
  const end = (s) => !s ? "" : /[。！？]$/.test(s) ? s : s + "。";

  function say(text, n = 60) { return end(shorten(clean(text), n)); }

  // 「修改 · Orbit42」→ 誰在講：秘書就叫秘書；組員說「Orbit42 那邊」（畫面不顯示英文名，11-22）
  function speaker(head) {
    const parts = String(head || "").split(/\s*[·・]\s*/).map((x) => x.trim()).filter(Boolean);
    const role = parts[0] || "", proj = clean(parts[1] || "");
    if (!role) return "有個組員";
    if (role === "秘書" || !proj) return clean(role) || "有個組員";
    return `${proj} 那邊`;
  }
  function topic(doing) {
    const d = clean(String(doing || "").replace(/^完成[：:]/, "")).replace(/[。！？]+$/, "");
    return !d || d === "待命" ? "" : shorten(d, 16).replace(/[。！？]+$/, "");
  }
  function gist(t, n = 28) {
    const g = clean(t);
    return g && /[\p{L}\p{N}]/u.test(g) ? end(shorten(g, n)) : "";
  }

  /* kind：review（做完等你看）／done（完成）／ask（需要你）／quiet（N 分鐘沒動靜）／wait（等外部）／stuck（卡住）
     f：{ name（職責 · 主專案）, doing, result, ask, why, minutes } */
  function card(kind, f = {}) {
    const who = speaker(f.name), d = topic(f.doing);
    const tail = (x, n) => { const g = gist(x, n); return g && (!d || !g.startsWith(d)) ? g : ""; };
    switch (kind) {
      case "review": return (d ? `${who}做完了${d}，等你看。` : `${who}這一輪做完了，等你看。`) + tail(f.result);
      case "done": return (d ? `${who}的${d}做好了。` : `${who}做好了。`) + tail(f.result);
      case "ask": return (d ? `${who}做${d}，有事問你。` : `${who}有事問你。`) + tail(f.ask, 30);
      case "quiet": return `${who}${d ? "做" + d + "，" : ""}已經 ${f.minutes} 分鐘沒動靜，可能卡住了。`;
      case "wait": return `${who}在等外面的事。` + tail(f.result, 24);
      case "stuck": return `${who}${d ? "做" + d + "，" : ""}卡住了。` + tail(f.why, 24);
      default: return say(f.result || f.ask || "");
    }
  }

  root.Spoken = { clean, shorten, say, card, speaker, zh, clock };
})(typeof window !== "undefined" ? window : globalThis);
