#!/usr/bin/env python3
"""記下現在裝著哪一版 Orbit42：~/Library/Application Support/Orbit42/board/installed.json（11-28 Fiona2）
  installed_record.py build   --app APP --who 誰 [--forced 原因] [--root 資料夾]   build_app.sh 裝好後叫
  installed_record.py restart --app APP --who 誰 --pid 程序編號                     restart_app.sh 重開成功後叫
為什麼：這個檔是 ShoWork42 安裝器留下的，改名 Orbit42 後沒人寫，停在 11-23；看板和組員想知道「裝著的是哪顆」只能去翻 Info.plist。
commit 一律從 App 的 Info.plist（OrbitGitCommit）讀，不信呼叫端：跟 StaleAsks、打包前檢查看的是同一個來源。
寫入先寫暫存檔再 rename（不會有人讀到半個檔）。寫不成只印警告、exit 0：不能因為記錄失敗擋掉打包或重開。
ORBIT_INSTALLED 可換檔案路徑（測試用）。"""
import argparse, json, os, plistlib, sys, tempfile, time

PATH = os.environ.get("ORBIT_INSTALLED") or os.path.expanduser("~/Library/Application Support/Orbit42/board/installed.json")


def now(): return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def app_commit(app):
    try:
        with open(os.path.join(app, "Contents/Info.plist"), "rb") as f:
            return plistlib.load(f).get("OrbitGitCommit") or None
    except (OSError, plistlib.InvalidFileException, ValueError):
        return None


def load():
    try:
        with open(PATH) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def save(d):
    os.makedirs(os.path.dirname(PATH), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(PATH), prefix=".installed.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(d, f, ensure_ascii=False, indent=1); f.write("\n")
        os.replace(tmp, PATH)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise


def build(a):
    prev = load()
    d = {"commit": app_commit(a.app), "dirty": False, "root": a.root, "app": a.app, "at": now(), "who": a.who,
         "forced": bool(a.forced), "forceReason": a.forced or None,
         "restartedAt": None, "restartedBy": None, "pid": None}
    if prev.get("commit"):
        d["previous"] = {"commit": prev["commit"], "at": prev.get("at")}
    return d


def restart(a):
    d = load()
    c = app_commit(a.app)
    if c and c != d.get("commit"):
        # 沒經過 build_app.sh 換的包（例如 swap_app.py、手動複製）：以 App 實際記的為準
        prev = d
        d = {"commit": c, "dirty": None, "root": None, "app": a.app, "at": None, "who": None, "forced": None,
             "forceReason": None, "note": "裝的時候沒記到（不是 build_app.sh 裝的），重開時從 Info.plist 補"}
        if prev.get("commit"):
            d["previous"] = {"commit": prev["commit"], "at": prev.get("at")}
    d.update({"restartedAt": now(), "restartedBy": a.who, "pid": a.pid})
    return d


def main():
    p = argparse.ArgumentParser()
    p.add_argument("cmd", choices=["build", "restart"])
    p.add_argument("--app", required=True)
    p.add_argument("--who", default="終端機")
    p.add_argument("--forced", default="")
    p.add_argument("--root", default=None)
    p.add_argument("--pid", type=int, default=None)
    a = p.parse_args()
    try:
        save(build(a) if a.cmd == "build" else restart(a))
        print(f"已記進 {PATH}")
    except Exception as e:       # 記錄失敗不擋打包／重開
        print(f"注意：寫不進 {PATH}（{e}），裝著的版本照樣可從 Info.plist 的 OrbitGitCommit 查", file=sys.stderr)


if __name__ == "__main__":
    main()
