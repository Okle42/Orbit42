#!/bin/zsh
# Orbit42 iPhone App 配對：打開 Mac 的網頁戰情中心（只綁 Tailscale、要密碼），把連線網址做成 QR code 顯示在螢幕上，用 App 的「掃 QR code」掃。
# 要你本人在自己的終端機跑（ShoWork 規定：開關與密碼只給本人操作，Claude Code 裡會被拒）。密碼只在這台 Mac 上，不會給 AI。
#   zsh ~/github-repos/Orbit42/scripts/phone_pair.sh          第一次：打開並產生網址
#   zsh ~/github-repos/Orbit42/scripts/phone_pair.sh --new    換一組新密碼（舊的手機要重新掃）
set -e
SW="$HOME/Library/Application Support/ShoWork42/bin/showork"
out=$("$SW" web enable 2>&1) || { print -r -- "$out"; exit 1; }
url=$(print -r -- "$out" | grep -oE 'http://[0-9.]+:[0-9]+/\?t=[0-9a-f]+' | head -1)
if [[ -z "$url" || "$1" == "--new" ]]; then
  # 已經開過、網址不重印 ⇒ 換一組新的（只有這樣才拿得到網址）
  out=$("$SW" web rotate 2>&1)
  url=$(print -r -- "$out" | grep -oE 'http://[0-9.]+:[0-9]+/\?t=[0-9a-f]+' | head -1)
fi
[[ -z "$url" ]] && { print -r -- "$out"; print "沒拿到網址（Tailscale 連上了嗎？）"; exit 1; }
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
open "$png"
print "已打開 QR code：用 iPhone 的 Orbit42 →「掃 QR code」掃它（手機要先連上 Tailscale）。"
print "掃完就把那個圖片視窗關掉；這個網址就是密碼，別傳給別人。"
