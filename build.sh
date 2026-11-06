#!/bin/bash
# 編譯並打包成 Speakin.app：./build.sh
set -euo pipefail
cd "$(dirname "$0")"
# 開發版多編「實驗功能」（Experimental.swift，不放上 GitHub）；正式版不會有
if [ "${SIGN:-Apple Development}" = "Apple Development" ]; then swift build -c release -Xswiftc -DEXPERIMENTAL; else swift build -c release; fi
APP="${APP:-Speakin.app}"   # 同事版另外放 dist/，不蓋掉自己用的（換簽章會讓系統權限掉）
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Speakin "$APP/Contents/MacOS/Speakin"
mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Vendor/TranscribeCpp.xcframework/macos-arm64_x86_64/CTranscribe.framework "$APP/Contents/Frameworks/"
# 開發版用另一個身分，跟同事版（cc.speakin.app）的系統權限分開，兩個可以同時裝
SIGN="${SIGN:-Apple Development}"
if [ "$SIGN" = "Apple Development" ]; then ID=cc.speakin.app.dev NAME="Speakin Dev"; else ID=cc.speakin.app NAME=Speakin; fi
VERSION=$(cat VERSION)
# 檢查更新的網址（latest.json）；沒設就不檢查
UPDATE_KEY=""; [ -n "${UPDATE_URL:-}" ] && UPDATE_KEY="<key>SpeakinUpdateURL</key><string>$UPDATE_URL</string>"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>Speakin</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  $UPDATE_KEY
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSMicrophoneUsageDescription</key><string>Speakin 需要麥克風把你說的話轉成文字。</string>
</dict></plist>
EOF
# 用固定的開發者憑證簽，重新編譯後系統權限才不會掉；給同事用的版本走 ./release.sh（Developer ID＋公證）
FLAGS=(--force -s "$SIGN")
[ "$SIGN" != "Apple Development" ] && FLAGS+=(--options runtime --timestamp)
codesign "${FLAGS[@]}" "$APP/Contents/Frameworks/CTranscribe.framework"
codesign "${FLAGS[@]}" --entitlements Resources/Speakin.entitlements "$APP"
echo "完成：$(pwd)/$APP"
