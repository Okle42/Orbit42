# Orbit42 iPhone App

連到 Mac 上的 Orbit42：看球體、看衛星的終端機畫面（唯讀）、回答答案卡。App 內建 Tailscale，不用另外開 Tailscale App。

## 建置
1. TailscaleKit（23 MB，不放進 git）：
   ```bash
   git clone https://github.com/tailscale/libtailscale ~/github-repos/_vendor/libtailscale
   cd ~/github-repos/_vendor/libtailscale/swift && make ios      # 要 Go
   mkdir -p ~/github-repos/Orbit42/ios/Frameworks
   cp -R build/Build/Products/Release-iphoneos/TailscaleKit.framework ~/github-repos/Orbit42/ios/Frameworks/
   ```
2. `cd ios && xcodegen`，用 Xcode 打開 Orbit42Phone.xcodeproj

## 第一次使用
1. App 上方「Tailscale」那格按「登入」，用 okle42.ai 帳號登入（之後會記住）
2. Mac 上連點兩下桌面的「Orbit42 手機配對」（或跑 scripts/phone_pair.sh），用 App 掃 QR code
