#!/bin/bash
# 建置「HomePlay Home」HomeKit 幫手（Mac Catalyst）並安裝。
# 用法：bash tooling/make-home-helper.sh [目的資料夾，預設 ~/Applications]
#
# 注意：這是開發者簽章（team DQ45KFVHJ8 自動簽章），只能在已登錄到該 team 的 Mac 上執行；
# 不可以包進已公證的 Developer ID 版 HomePlay.app。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Helpers/HomeBridge"
DEST_DIR="${1:-$HOME/Applications}"
DEST="$DEST_DIR/HomePlay Home.app"
BUILD="$SRC/build"

cd "$SRC"
xcodegen generate --quiet
# 新 bundle id 第一次要先用 iOS 目的地註冊 App ID（含 HomeKit），之後 Catalyst 才簽得起來；兩步都跑，已註冊時很快
xcodebuild -project HomePlayHome.xcodeproj -scheme HomePlayHome -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$BUILD" -allowProvisioningUpdates build -quiet || true
xcodebuild -project HomePlayHome.xcodeproj -scheme HomePlayHome -configuration Release \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath "$BUILD" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build -quiet

APP="$(find "$BUILD/Build/Products" -maxdepth 2 -name 'HomePlay Home.app' | head -1)"
[ -d "$APP" ] || { echo "找不到建好的 App" >&2; exit 1; }
mkdir -p "$DEST_DIR"
pkill -f "HomePlay Home.app/Contents/MacOS" 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "已安裝：$DEST"
codesign -d --entitlements - "$DEST" 2>&1 | grep -E 'homekit|application-identifier' || { echo "警告：簽章裡沒有 homekit 權利" >&2; exit 1; }
