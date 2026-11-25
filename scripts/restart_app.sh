#!/bin/zsh
# 重開 ~/Applications/Orbit42.app（正常結束 → 等它真的關掉 → 再打開），結果寫 ~/Library/Logs/Orbit42/restart.log。
#   scripts/restart_app.sh "原因"
# 11-24 Keng「叫你重開，關掉之後都沒有幫我重新開啟」：之前用程式名稱找 Orbit42（pgrep -f 會比到腳本自己、
# pgrep -x 會比到 iPhone 模擬器裡同名的 Orbit42），永遠以為還沒關 ⇒ 改成先記下「這支 App 的程序編號」，等那個編號消失。
# 自己脫離呼叫它的終端機（setsid）：從衛星裡跑也不會跟著 Orbit42 一起被關掉。
set -u
APP="$HOME/Applications/Orbit42.app"
BIN="$APP/Contents/MacOS/Orbit42"
LOG="$HOME/Library/Logs/Orbit42/restart.log"
mkdir -p "${LOG:h}"
if [[ "${ORBIT_RESTART_DETACHED:-}" != 1 ]]; then
  export ORBIT_RESTART_DETACHED=1
  exec /usr/bin/python3 -I -c '
import os, sys
if os.fork(): sys.exit(0)
os.setsid()
if os.fork(): os._exit(0)
os.execv("/bin/zsh", ["/bin/zsh"] + sys.argv[1:])
' "$0" "$@"
fi
exec >>"$LOG" 2>&1 </dev/null
say() { echo "$(date '+%m-%d %H:%M:%S') $*"; }
# 只認完整路徑等於這支 App 的程序（模擬器裡同名的不算）
pids() { ps -axo pid=,command= | awk -v b="$BIN" '{p=$1; $1=""; sub(/^ /,""); if ($0 == b) print p}'; }
say "重開：${1:-（沒寫原因）}"
old=($(pids))
alive=0
if (( ${#old} )); then
  osascript -e 'tell application id "ai.okle42.orbit42" to quit' || say "osascript 結束失敗"
  for i in {1..40}; do
    alive=0; for p in $old; do kill -0 $p 2>/dev/null && alive=1; done
    (( alive )) || break; sleep 1
  done
  if (( alive )); then say "等 40 秒還沒關（程序 $old），不重開"; exit 1; fi
  say "已關掉（程序 $old）"
else
  say "原本就沒開"
fi
sleep 1
cur=($(pids))
if (( ${#cur} )); then say "已經有人先打開了（程序 $cur），不重複開"; exit 0; fi
open "$APP"; sleep 3
new=($(pids))
if (( ${#new} )); then say "已重開（程序 $new）"; /usr/bin/python3 -I "${0:A:h}/swap_app.py" clean; else say "打開失敗：找不到新的 Orbit42 程序"; exit 1; fi
