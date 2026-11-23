#!/bin/zsh
# Builds Orbit42.app (release) into ~/Applications and puts a shortcut on the Desktop.
#   scripts/build_app.sh            # build + install
set -euo pipefail
cd "${0:A:h}/.."
swift build -c release
APP="$HOME/Applications/Orbit42.app"
TMP="$APP.new"
SW="Packages/ShoWork42"; [ -d "$SW" ] || SW=".build/checkouts/ShoWork42"   # 平常用 GitHub 抓下來的；暫時 swift package edit 時用本機那份（跟 ios/project.yml 同一個順序）
rm -rf "$TMP"; mkdir -p "$TMP/Contents/MacOS" "$TMP/Contents/Resources"
cp .build/release/Orbit42 "$TMP/Contents/MacOS/Orbit42"
cp Support/Info.plist "$TMP/Contents/Info.plist"
cp assets/Orbit42.icns "$TMP/Contents/Resources/Orbit42.icns"
rsync -a --exclude .DS_Store Web/ "$TMP/Contents/Resources/OrbitWeb/"                      # login + satellite terminals
rsync -a --exclude bench --exclude .DS_Store --exclude '*.md' "$SW/windows/ShoWork.Win/Board/Web/" "$TMP/Contents/Resources/Web/"   # the full sphere
cp "$SW/scripts/flow_audit.py" "$TMP/Contents/Resources/flow_audit.py"
ID=$(security find-identity -v -p codesigning | awk '/Developer ID Application|Apple Development/ {print $2; exit}')
codesign -f -s "${ID:--}" --identifier ai.okle42.orbit42 "$TMP" >/dev/null
rm -rf "$APP"; mv "$TMP" "$APP"
# Desktop shortcut (Finder alias, so the icon shows and double-click opens the app)
osascript -e 'tell application "Finder" to if not (exists alias file "Orbit42" of desktop) then make alias file to (POSIX file "'"$APP"'") at desktop with properties {name:"Orbit42"}' >/dev/null
echo "$APP"
