#!/bin/bash
# 打包給同事用的版本：Developer ID 簽章 → Apple 公證 → 釘上公證結果 → dist/Speakin.dmg（打開後拖進「應用程式」）
# 公證帳號存在鑰匙圈的 notary 設定檔（xcrun notarytool store-credentials notary）
set -euo pipefail
cd "$(dirname "$0")"
SIGN="Developer ID Application: CHEN YU SHENG (R39P3Y27B7)"
mkdir -p dist && rm -rf dist/Speakin.zip dist/Speakin.dmg dist/dmg
# 新版放 GitHub Releases：App 固定查「最新一版」的 latest.json，GitHub 會自動轉到最新那版
REPO=sheng0122/speakin
UPDATE_URL="https://github.com/$REPO/releases/latest/download/latest.json" APP=dist/Speakin.app SIGN="$SIGN" ./build.sh
mkdir dist/dmg && ditto dist/Speakin.app dist/dmg/Speakin.app && ln -s /Applications dist/dmg/Applications
hdiutil create -volname Speakin -srcfolder dist/dmg -fs HFS+ -format UDZO dist/Speakin.dmg
rm -rf dist/dmg
codesign --sign "$SIGN" --timestamp dist/Speakin.dmg
xcrun notarytool submit dist/Speakin.dmg --keychain-profile notary --wait
xcrun stapler staple dist/Speakin.dmg
spctl -a -vv -t open --context context:primary-signature dist/Speakin.dmg
V=$(cat VERSION)
printf '{"version":"%s","url":"https://github.com/%s/releases/download/v%s/Speakin.dmg"}\n' "$V" "$REPO" "$V" > dist/latest.json
echo "完成：$(pwd)/dist/Speakin.dmg（版本 $V）"
echo "發佈：GH_TOKEN=\$(gh auth token -u sheng0122) gh release create v$V dist/Speakin.dmg dist/latest.json -R $REPO -t \"Speakin $V\""
