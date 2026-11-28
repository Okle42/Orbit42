#!/bin/zsh
# Builds Orbit42.app (release) into ~/Applications and puts a shortcut on the Desktop.
#   scripts/build_app.sh            # build + install
set -euo pipefail
cd "${0:A:h}/.."
swift build -c release
APP="$HOME/Applications/Orbit42.app"
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
osascript -e 'tell application "Finder" to if not (exists alias file "Orbit42" of desktop) then make alias file to (POSIX file "'"$APP"'") at desktop with properties {name:"Orbit42"}' >/dev/null
echo "$APP"
