#!/bin/zsh
# 重開 ~/Applications/Orbit42.app（正常結束 → 等它真的關掉 → 再打開），結果寫 ~/Library/Logs/Orbit42/restart.log。
#   scripts/restart_app.sh "原因"
# 11-24 Keng「叫你重開，關掉之後都沒有幫我重新開啟」：之前用程式名稱找 Orbit42（pgrep -f 會比到腳本自己、
# pgrep -x 會比到 iPhone 模擬器裡同名的 Orbit42），永遠以為還沒關 ⇒ 改成先記下「這支 App 的程序編號」，等那個編號消失。
# 自己脫離呼叫它的終端機（setsid）：從衛星裡跑也不會跟著 Orbit42 一起被關掉。
# 11-28 B 組 LYZP9（Keng 核可）：重開前先等鍵盤滑鼠閒置。最近 ORBIT_RESTART_IDLE 秒（預設 8）內有在用就先不關，
# 每秒看一次 HIDIdleTime；等超過 ORBIT_RESTART_WAIT 秒（預設 180）還沒停手 ⇒ 放棄這次重開、寫進 restart.log、exit 2。
# 讀不到閒置時間也不重開（feedback_等閒置逾時要停不要硬重開：沒等到閒置不准硬重開）。
set -u
APP="${ORBIT_RESTART_APP:-$HOME/Applications/Orbit42.app}"
BIN="$APP/Contents/MacOS/Orbit42"
LOG="${ORBIT_RESTART_LOG:-$HOME/Library/Logs/Orbit42/restart.log}"
NEED_IDLE="${ORBIT_RESTART_IDLE:-8}"
MAX_WAIT="${ORBIT_RESTART_WAIT:-180}"
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
# 鍵盤滑鼠閒置秒數（ORBIT_IDLE_CMD 給測試換掉）
idle() { if [[ -n "${ORBIT_IDLE_CMD:-}" ]]; then eval "$ORBIT_IDLE_CMD"; else ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'; fi; }
waited=0
while :; do
  i=$(idle 2>/dev/null)
  if [[ ! "$i" =~ '^[0-9]+$' ]]; then say "讀不到鍵盤閒置時間，這次不重開"; exit 2; fi
  (( i >= NEED_IDLE )) && break
  if (( waited >= MAX_WAIT )); then say "你一直在用（等了 ${waited} 秒都沒有閒置 ${NEED_IDLE} 秒），這次不重開，等你停手再重開"; exit 2; fi
  (( waited == 0 )) && say "鍵盤 ${i} 秒前還在用，等閒置 ${NEED_IDLE} 秒再重開（最多等 ${MAX_WAIT} 秒）"
  sleep 1; (( waited++ ))
done
(( waited > 0 )) && say "等了 ${waited} 秒，已閒置 ${i} 秒，開始重開"
old=($(pids))
alive=0
if (( ${#old} )); then
  # 對準程序編號請它結束：換過包的程式位置變了、或有別支同 id 的程式時，用 id 會送錯（11-25 送到測試程式過）
  for p in $old; do
    r=$(osascript -l JavaScript -e "ObjC.import('AppKit'); const a=\$.NSRunningApplication.runningApplicationWithProcessIdentifier($p); a.isNil() ? 'nil' : String(a.terminate)" 2>&1)
    [[ "$r" == true ]] || say "請程序 $p 結束失敗：$r"
  done
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
