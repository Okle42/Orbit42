#!/usr/bin/env python3
"""戰情列：Mac Orbit42（?orbit=1&askfloat=1）只留「● 等你答」；沒帶 askfloat（手機、Windows、戰情中心）答案卡照舊。無頭 Chrome。"""
import functools, http.server, json, os, shutil, subprocess, sys, tempfile, threading
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
WEB = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../Engine/windows/ShoWork.Win/Board/Web"))
JS = """<script type=module>
const msgs = []; window.webkit = { messageHandlers: { sphere: { postMessage: m => msgs.push(m) } } };
setTimeout(() => { let o = {}; try {
  window.karaUpdate({ five_hour: 1, seven_day: 2, sessions: 2, runs: [], team: [{ name: "甲", status: "需要你", sessionId: "s1", askId: "A", ask: "要嗎", options: ["好（建議）", "不要"] }, { name: "乙", status: "進行中", sessionId: "s2" }] });
  const t = document.querySelectorAll(".askTag"); o.tags = t.length; o.row = t[0]?.closest(".row").dataset.i; o.card = document.getElementById("askCard").classList.contains("on"); o.opts = document.querySelectorAll("#askCard .opt").length;
  msgs.length = 0; t[0]?.click(); o.sent = msgs.map(m => m.action + ":" + (m.sessionId || ""));
  msgs.length = 0; for (const key of ["1", "Enter"]) document.body.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true })); o.undo = document.getElementById("askUndo").classList.contains("on");
} catch (e) { o.err = e.stack; } fetch("/result", { method: "POST", body: JSON.stringify(o) }); }, 2500);
</script>"""
tmp = tempfile.mkdtemp(prefix="asktag-"); shutil.copytree(WEB, tmp + "/w")
with open(tmp + "/w/sphere.html", "a", encoding="utf-8") as f: f.write(JS)
got, done = [], threading.Event()


class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *x): pass

    def do_POST(self):
        got.append(json.loads(self.rfile.read(int(self.headers["Content-Length"])))); done.set(); self.send_response(204); self.end_headers()


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(H, directory=tmp + "/w")); threading.Thread(target=srv.serve_forever, daemon=True).start()
bad = 0
for q, want in (("orbit=1&askfloat=1", dict(tags=1, row="0", card=False, sent=["askShow:s1"], undo=False)), ("orbit=1", dict(tags=0, card=True, opts=2, undo=True)), ("", dict(tags=0, card=True, opts=2))):
    got.clear(); done.clear()
    p = subprocess.Popen([CHROME, "--headless=new", "--no-first-run", "--remote-debugging-port=0", "--enable-unsafe-swiftshader", f"--user-data-dir={tmp}/r", "--window-size=1440,900", f"http://127.0.0.1:{srv.server_port}/sphere.html?{q}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    done.wait(40); p.terminate(); p.wait(20)
    r = got[0] if got else {"err": "沒跑完"}; miss = {k: (v, r.get(k)) for k, v in want.items() if r.get(k) != v}
    bad += bool(miss or r.get("err")); print(q or "(一般)", "通過" if not miss and not r.get("err") else f"失敗 {miss} {r.get('err', '')}")
srv.shutdown(); shutil.rmtree(tmp, ignore_errors=True); sys.exit(bad)
