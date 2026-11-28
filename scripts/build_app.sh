#!/bin/zsh
# Builds Orbit42.app (release) into ~/Applications and puts a shortcut on the Desktop.
#   scripts/build_app.sh            # build + install
#   scripts/build_app.sh --check    # 只跑打包前檢查，不打包（過了 exit 0，擋下 exit 3）
# 11-28 T1128183531 打包前檢查（Keng：「我隨時測過改好都要直接並進主線直接分別裝起來」；Tina 從分支打包蓋掉別人的修正）：
#   (a) 先 git fetch；要打包的 HEAD 必須等於 origin/main、工作區乾淨、不是 worktree（只准從主資料夾的 main 打包）
#   (b) 現在裝著的 App（Info.plist 的 OrbitGitCommit）必須是 HEAD 的祖先，不然就是倒退；裝著的版本沒記 commit 也擋（查不到不算過）
#   (c) 唯一例外：ORBIT_BUILD_FORCE="原因"，原因和沒過的項目都寫進 ~/Library/Logs/Orbit42/build.log
#   每次打包（過、擋、強制）都記一筆：時間、誰、HEAD、裝著的版本、結果
set -euo pipefail
cd "${0:A:h}/.."
APP="${ORBIT_BUILD_APP:-$HOME/Applications/Orbit42.app}"
BUILD_LOG="${ORBIT_BUILD_LOG:-$HOME/Library/Logs/Orbit42/build.log}"
mkdir -p "${BUILD_LOG:h}"
# 誰在打包：Claude Code 裡跑的用它的英文名，不然寫終端機
WHO="終端機"
if [[ -n "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
  NAMEF="$HOME/Library/Application Support/Orbit42/board/names/$CLAUDE_CODE_SESSION_ID.json"
  WHO=$(/usr/bin/python3 -I -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("name") or sys.argv[2])
except Exception: print(sys.argv[2])' "$NAMEF" "session ${CLAUDE_CODE_SESSION_ID[1,8]}")
fi
blog() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$BUILD_LOG"; }
PROBLEMS=()
git fetch -q origin || PROBLEMS+=("抓不到 origin（git fetch 失敗），不知道 origin/main 在哪")
HEAD_C=$(git rev-parse HEAD)
MAIN_C=$(git rev-parse -q --verify origin/main || echo "")
[[ -n "$MAIN_C" && "$HEAD_C" == "$MAIN_C" ]] || PROBLEMS+=("要打包的 HEAD ${HEAD_C[1,7]}（分支 $(git rev-parse --abbrev-ref HEAD)）不是 origin/main ${MAIN_C[1,7]}：只准從 main 打包，先把改動併進 main、推上去")
[[ "$(git rev-parse --git-dir)" == "$(git rev-parse --git-common-dir)" ]] || PROBLEMS+=("這裡是 worktree（$PWD）：只准從主資料夾打包")
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || PROBLEMS+=("工作區有還沒 commit 的改動：打包出來的跟 commit 對不上")
INST=""
if [[ -f "$APP/Contents/Info.plist" ]]; then
  INST=$(/usr/bin/plutil -extract OrbitGitCommit raw "$APP/Contents/Info.plist" 2>/dev/null || echo "")
  if [[ -z "$INST" ]]; then
    PROBLEMS+=("裝著的 App 沒記是哪個 commit（4dc1503 以前的版本），看不出會不會倒退")
  elif ! git cat-file -e "$INST^{commit}" 2>/dev/null; then
    PROBLEMS+=("裝著的 App 是 ${INST[1,7]}，這個 repo 找不到這顆 commit（可能是別的分支打包、沒推上來），看不出會不會倒退")
  elif ! git merge-base --is-ancestor "$INST" "$HEAD_C"; then
    PROBLEMS+=("倒退：裝著的 ${INST[1,7]} 不在要打包的 ${HEAD_C[1,7]} 裡面，裝下去會蓋掉 ${INST[1,7]} 有、這版沒有的修正")
  fi
fi
INST_S="${INST[1,7]}"
SUMMARY="誰：$WHO｜HEAD ${HEAD_C[1,7]}｜裝著 ${INST_S:-（沒有）}"
if (( ${#PROBLEMS} )); then
  if [[ -n "${ORBIT_BUILD_FORCE:-}" ]]; then
    blog "強制打包（ORBIT_BUILD_FORCE：$ORBIT_BUILD_FORCE）｜$SUMMARY｜沒過：${(j:；:)PROBLEMS}"
    echo "注意：強制打包（$ORBIT_BUILD_FORCE），以下沒過的已記進 $BUILD_LOG：" >&2
    printf '  ・%s\n' "${PROBLEMS[@]}" >&2
  else
    blog "擋下｜$SUMMARY｜${(j:；:)PROBLEMS}"
    echo "打包前檢查沒過，停下（沒有打包、沒有動到裝著的 App）：" >&2
    printf '  ・%s\n' "${PROBLEMS[@]}" >&2
    echo "真的要裝（例如救急）：ORBIT_BUILD_FORCE=\"原因\" scripts/build_app.sh，原因會記進 $BUILD_LOG" >&2
    exit 3
  fi
else
  echo "打包前檢查通過：$SUMMARY"
fi
if [[ "${1:-}" == "--check" ]]; then blog "只檢查（--check）｜$SUMMARY｜${#PROBLEMS} 項沒過"; exit 0; fi
blog "打包｜$SUMMARY"
swift build -c release
TMP="$APP.new"
SW="Engine"   # 引擎和球體網頁都在這個 repo（2026-11-24 起不再抓 Orbit42）
rm -rf "$TMP"; mkdir -p "$TMP/Contents/MacOS" "$TMP/Contents/Resources"
cp .build/release/Orbit42 "$TMP/Contents/MacOS/Orbit42"
cp Support/Info.plist "$TMP/Contents/Info.plist"
# 11-28 記下這包是哪個 commit：組員問「要不要裝 xxx」而裝著的版本已經含它 ⇒ 看板自動撤題（StaleAsks.swift）
/usr/bin/plutil -replace OrbitGitCommit -string "$(git rev-parse HEAD)" "$TMP/Contents/Info.plist"
# 11-26 Orbit42 帳號（Google 登入）的金鑰和用戶端 ID 不進 repo：打包時從本機檔讀進 Info.plist
#   檔案：~/Library/Application Support/Orbit42/secrets.plist（ORBIT_SECRETS 可換路徑），要有 OrbitFirebaseAPIKey、OrbitGoogleClientID 兩個字串
#   沒有這個檔：照樣打包，但會清楚說明；App 的帳號頁會顯示「這版還沒設定 Google 登入」
SECRETS="${ORBIT_SECRETS:-$HOME/Library/Application Support/Orbit42/secrets.plist}"
if [[ -f "$SECRETS" ]]; then
  for k in OrbitFirebaseAPIKey OrbitGoogleClientID; do
    v=$(/usr/bin/plutil -extract "$k" raw "$SECRETS" 2>/dev/null) || { echo "錯誤：$SECRETS 少了 $k" >&2; exit 1; }
    /usr/bin/plutil -replace "$k" -string "$v" "$TMP/Contents/Info.plist"
  done
  echo "已從 $SECRETS 帶入 Google 登入設定"
else
  echo "注意：找不到 $SECRETS ⇒ 這版沒有 Google 登入（帳號頁會顯示「還沒設定」）。要開：建這個檔放 OrbitFirebaseAPIKey、OrbitGoogleClientID" >&2
fi
# 11-24 圖示分深淺色：assets/Orbit42.icon（Icon Composer 格式，含深色外觀）用 actool 編成 Assets.car＋舊系統用的 Orbit42.icns
xcrun actool "$PWD/assets/Orbit42.icon" --compile "$TMP/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 \
  --app-icon Orbit42 --output-partial-info-plist "$TMP.icon.plist" --output-format human-readable-text >/dev/null
rm -f "$TMP.icon.plist"
cp assets/Orbit42-dark.png assets/Orbit42-light.png "$TMP/Contents/Resources/"      # App 開著時 Dock 圖示跟著深淺色換（DockIcon.swift）
rsync -a --exclude .DS_Store Web/ "$TMP/Contents/Resources/OrbitWeb/"                      # login + satellite terminals
rsync -a --exclude bench --exclude office.html --exclude office.js --exclude office.css --exclude office-w6.js --exclude kit.js --exclude demo-data.js --exclude scene/ --exclude ui/ --exclude .DS_Store --exclude '*.md' "$SW/windows/Orbit42.Engine.Win/Board/Web/" "$TMP/Contents/Resources/Web/"   # the full sphere
mkdir -p "$TMP/Contents/Resources/convert"; cp Support/convert/*.py "$TMP/Contents/Resources/convert/"      # 3D 檔案轉檔
cp "$SW/scripts/flow_audit.py" "$TMP/Contents/Resources/flow_audit.py"
ID=$(security find-identity -v -p codesigning | awk '/Developer ID Application|Apple Development/ {print $2; exit}')
codesign -f -s "${ID:--}" --identifier ai.okle42.orbit42 "$TMP" >/dev/null
# 11-26 衛星裡的 AI 操作網頁用的指令：放在 orbit 旁邊（寄信刪檔付款類動作，Orbit42 會先問）
BIN_DIR="$HOME/Library/Application Support/Orbit42/bin"; mkdir -p "$BIN_DIR"
# 11-28 orbit 指令也跟著換（以前只換 App，bin/orbit 會停在舊版）：先把整個舊 bin/ 備份，再 cp 成 .new、mv 換上、cmp 核對
REL_BIN="$(swift build -c release --show-bin-path)"
[[ -x "$REL_BIN/orbit" ]] || { echo "錯誤：找不到 release 版 orbit（$REL_BIN/orbit）" >&2; exit 1; }
BACKUP="$HOME/Library/Application Support/Orbit42/backup/bin-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${BACKUP:h}"; cp -Rp "$BIN_DIR" "$BACKUP"
for pair in "$REL_BIN/orbit:orbit" "scripts/orbit-web:orbit-web"; do
  src="${pair%:*}"; dst="$BIN_DIR/${pair##*:}"
  cp "$src" "$dst.new"; chmod +x "$dst.new"; mv -f "$dst.new" "$dst"
  cmp -s "$src" "$dst" || { echo "錯誤：$dst 換完跟來源不一樣（備份在 $BACKUP）" >&2; exit 1; }
done
echo "已換 orbit、orbit-web（舊 bin/ 備份在 $BACKUP）"
/usr/bin/python3 -I scripts/swap_app.py install "$TMP" --app "$APP"      # 原子互換；舊包留到下次重開才清（刪掉執行中的舊包，系統會認不得它）
# Desktop shortcut (Finder alias, so the icon shows and double-click opens the app)
blog "裝好｜$SUMMARY"
/usr/bin/python3 -I scripts/installed_record.py build --app "$APP" --who "$WHO" --root "$PWD" --forced "${ORBIT_BUILD_FORCE:-}" || true   # 11-28 board/installed.json 跟著更新
osascript -e 'tell application "Finder" to if not (exists alias file "Orbit42" of desktop) then make alias file to (POSIX file "'"$APP"'") at desktop with properties {name:"Orbit42"}' >/dev/null
echo "$APP"
