#!/bin/zsh
# Orbit42 iPhone App 配對：打開 Mac 的網頁戰情中心（只綁 Tailscale、要密碼），把連線網址做成 QR code 顯示在螢幕上，用 App 的「掃 QR code」掃。
# 要你本人在自己的終端機跑（ShoWork 規定：開關與密碼只給本人操作，Claude Code 裡會被拒）。密碼只在這台 Mac 上，不會給 AI。
#   zsh ~/github-repos/Orbit42/scripts/phone_pair.sh          第一次：打開並產生網址
#   zsh ~/github-repos/Orbit42/scripts/phone_pair.sh --new    換一組新密碼（已配對的手機要重新掃；平常不用）
set -e
SW="$HOME/Library/Application Support/ShoWork42/bin/showork"
# 埠：預設 8742；被別的程式佔走（11-23：AIStar 示範伺服器聽 127.0.0.1:8742 ⇒ 綁不上、手機連不到）就往後找空的
port=8742
taken() { [[ -n "$(lsof -nP -iTCP:$1 -sTCP:LISTEN 2>/dev/null | grep -v -E '^COMMAND|Orbit42|ShoWorkA')" ]]; }
while taken $port; do port=$((port + 1)); [[ $port -gt 8790 ]] && { print "8742–8790 都被佔走了"; exit 1; }; done
out=$("$SW" web enable --port $port 2>&1) || { print -r -- "$out"; exit 1; }
sleep 2   # 讓 Orbit42／ShoWorkAgent 收到通知、在新埠上開好
# 11-23 修：原本「已經開過就換新密碼」⇒ 每點一次就換一組，之前掃過的手機全部變成「token 不對」。
# 改成照現有的密碼組網址（你本人跑的，讀得到自己的 0600 檔），只有 --new 才換新密碼
if [[ "$1" == "--new" ]]; then "$SW" web rotate >/dev/null 2>&1; fi
WEB="$HOME/Library/Application Support/ShoWork42/web"
tok=$(tr -d '[:space:]' < "$WEB/token" 2>/dev/null)
ip=$(/usr/local/bin/tailscale ip -4 2>/dev/null | head -1)
[[ -z "$ip" ]] && ip=$(print -r -- "$out" | grep -oE 'http://[0-9.]+' | head -1 | sed 's#http://##')
url=""; [[ -n "$tok" && -n "$ip" ]] && url="http://$ip:$port/?t=$tok"
[[ -z "$url" ]] && { print -r -- "$out"; print "沒拿到網址（Tailscale 連上了嗎？）"; exit 1; }
print -rn -- "$url" | pbcopy        # 也拷到剪貼簿：iPhone（同一個 Apple ID 的通用剪貼板／iPhone 鏡像輸出）可以直接貼進 App
png="$TMPDIR/orbit42-pair.png"
cat > "$TMPDIR/orbit42qr.swift" <<'SWIFT'
import CoreImage; import AppKit
let a = CommandLine.arguments
let f = CIFilter(name: "CIQRCodeGenerator")!; f.setValue(Data(a[1].utf8), forKey: "inputMessage"); f.setValue("M", forKey: "inputCorrectionLevel")
let img = f.outputImage!.transformed(by: CGAffineTransform(scaleX: 14, y: 14))
let rep = NSBitmapImageRep(ciImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
SWIFT
swift "$TMPDIR/orbit42qr.swift" "$url" "$png" 2>/dev/null
rm -f "$TMPDIR/orbit42qr.swift"
# 用「快速查看」顯示（11-23：預覽程式卡住時 open 會 -1712 逾時、什麼都沒出現）；不行再退回 open
(qlmanage -p "$png" >/dev/null 2>&1 &) || open "$png"
if lsof -nP -iTCP:$port -sTCP:LISTEN 2>/dev/null | grep -q -E "Orbit42|ShoWorkA"; then print "Mac 這邊已經在 Tailscale 上等手機連線（埠 $port）。"
else print "⚠️ Mac 這邊還沒在埠 $port 上聽：Orbit42 或 ShoWork42 有開著嗎？"; fi
print "已打開 QR code：用 iPhone 的 Orbit42 →「掃 QR code」掃它（手機要先連上 Tailscale）。"
print "網址也拷貝到剪貼簿了（可以在 App 的網址欄貼上）。掃完或貼完就把圖片視窗關掉；這個網址就是密碼，別傳給別人。"
