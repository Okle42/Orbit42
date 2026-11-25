#!/usr/bin/env python3
"""整包原子互換 Orbit42.app，舊包留到下次重開才清（T1125194238）。
  swap_app.py install 新包.app [--app 已裝的.app]   驗簽章 → 跟已裝的互換
  swap_app.py ask ask.html [--app 已裝的.app]       複製已裝的、只換答案卡網頁、重簽、互換；執行中的 Orbit42 自己改用（縮起沒在用時）
  swap_app.py clean                               清掉沒有程序在用的舊包（restart_app.sh 重開成功後叫）
為什麼：原地重簽、或刪掉執行中的舊包，系統會認不得執行中的程式（實測：-67034、查不到身分、麥克風變拒絕）。"""
import argparse, ctypes, hashlib, os, re, shutil, subprocess, sys, time
HOME = os.path.expanduser("~")
OLD = os.environ.get("ORBIT_OLD_APPS") or HOME + "/Library/Application Support/Orbit42/old-apps"
NAME = re.compile(r"^Orbit42-\d{8}-\d{6}-\d+\.old$")      # 不用 .app 結尾：系統才不會把舊包當成另一支 Orbit42 打開
libc = ctypes.CDLL(None, use_errno=True)


def run(*a): return subprocess.run(a, capture_output=True, text=True)


def die(t): print("✗ " + t, file=sys.stderr); sys.exit(1)


def verify(p):
    r = run("codesign", "--verify", "--deep", "--strict", p)
    if r.returncode: die(f"簽章驗不過，不換：{p}\n{r.stderr.strip()}")


def req(p): return re.sub(r"^.*designated => ", "", run("codesign", "-d", "-r-", p).stdout.strip(), flags=re.S)


def slot():
    os.makedirs(OLD, mode=0o700, exist_ok=True); os.chmod(OLD, 0o700)
    return f"{OLD}/Orbit42-{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}.old"


def install(new, app):
    """new 會被搬走（變成 app）；原本的 app 變成 OLD 裡的舊包"""
    verify(new); s = slot()
    if not os.path.exists(app): os.rename(new, app); print("已裝（原本沒有）", app); return
    if req(new) != req(app) and "cdhash" not in req(app): die("簽章身分跟已裝的不同，不換")
    if os.stat(new).st_dev != os.stat(app).st_dev or os.stat(OLD).st_dev != os.stat(app).st_dev: die("不在同一顆磁碟，不能原子互換")
    os.rename(new, s)
    if libc.renamex_np(s.encode(), app.encode(), 2):      # RENAME_SWAP：沒有一刻讀不到或讀到半套
        e = os.strerror(ctypes.get_errno()); os.rename(s, new); die("互換失敗，沒有動到已裝的：" + e)
    verify(app); print("已換", app); print("舊包留在", s)


def ask(page, app):
    verify(app); s = slot() + ".new"
    ident = run("security", "find-identity", "-v", "-p", "codesigning").stdout
    m = re.search(r"\) ([0-9A-F]{40}) \"(?:Developer ID Application|Apple Development)", ident)
    if not m: die("找不到簽章憑證")
    r = run("ditto", app, s)
    if r.returncode: die(r.stderr)
    try:
        shutil.copyfile(page, s + "/Contents/Resources/Web/ask.html")
        r = run("codesign", "-f", "-s", m[1], "--identifier", "ai.okle42.orbit42", s)
        if r.returncode: die("重簽失敗：" + r.stderr)
        if req(s) != req(app): die("簽章身分跟已裝的不同，不換")
        install(s, app)
    finally:
        if os.path.isdir(s): shutil.rmtree(s)
    print("新網頁雜湊", hashlib.sha256(open(page, "rb").read()).hexdigest(), "\n核對：cat ~/Library/Application\\ Support/Orbit42/ask-page.json")


def in_use():
    lp = ctypes.CDLL("/usr/lib/libproc.dylib"); out = []
    for l in run("ps", "-axo", "pid=").stdout.split():
        b = ctypes.create_string_buffer(4096)
        if lp.proc_pidpath(int(l), b, 4096) > 0: out.append(os.path.realpath(b.value.decode(errors="replace")))
    if not out: die("讀不到程序清單，不清")
    return out


def clean():
    if not os.path.isdir(OLD): return
    used = in_use()
    for n in sorted(os.listdir(OLD)):
        p = os.path.realpath(f"{OLD}/{n}")
        if not NAME.match(n) or os.path.islink(f"{OLD}/{n}") or not os.path.isdir(p): continue
        if any(u.startswith(p + "/") for u in used): print("還在用，留著", n); continue
        shutil.rmtree(p); print("已清舊包", n)


ap = argparse.ArgumentParser(); ap.add_argument("what", choices=["install", "ask", "clean"]); ap.add_argument("path", nargs="?"); ap.add_argument("--app", default=HOME + "/Applications/Orbit42.app")
a = ap.parse_args()
if a.what == "clean": clean()
elif not a.path: ap.error("要給路徑")
elif a.what == "install": install(os.path.abspath(a.path), a.app)
else: ask(a.path, a.app)
