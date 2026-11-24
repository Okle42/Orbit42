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
# 11-24 圖示分深淺色：assets/Orbit42.icon（Icon Composer 格式，含深色外觀）用 actool 編成 Assets.car＋舊系統用的 Orbit42.icns
xcrun actool "$PWD/assets/Orbit42.icon" --compile "$TMP/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 \
  --app-icon Orbit42 --output-partial-info-plist "$TMP.icon.plist" --output-format human-readable-text >/dev/null
rm -f "$TMP.icon.plist"
cp assets/Orbit42-dark.png assets/Orbit42-light.png "$TMP/Contents/Resources/"      # App 開著時 Dock 圖示跟著深淺色換（DockIcon.swift）
rsync -a --exclude .DS_Store Web/ "$TMP/Contents/Resources/OrbitWeb/"                      # login + satellite terminals
rsync -a --exclude bench --exclude .DS_Store --exclude '*.md' "$SW/windows/ShoWork.Win/Board/Web/" "$TMP/Contents/Resources/Web/"   # the full sphere
mkdir -p "$TMP/Contents/Resources/convert"; cp Support/convert/*.py "$TMP/Contents/Resources/convert/"      # 3D 檔案轉檔
cp "$SW/scripts/flow_audit.py" "$TMP/Contents/Resources/flow_audit.py"
ID=$(security find-identity -v -p codesigning | awk '/Developer ID Application|Apple Development/ {print $2; exit}')
codesign -f -s "${ID:--}" --identifier ai.okle42.orbit42 "$TMP" >/dev/null
rm -rf "$APP"; mv "$TMP" "$APP"
# Desktop shortcut (Finder alias, so the icon shows and double-click opens the app)
osascript -e 'tell application "Finder" to if not (exists alias file "Orbit42" of desktop) then make alias file to (POSIX file "'"$APP"'") at desktop with properties {name:"Orbit42"}' >/dev/null
echo "$APP"
