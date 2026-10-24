#!/bin/zsh
# 打包 HomePlay.app（發佈到 GitHub Releases 用）：
#   Contents/MacOS/HomePlay             桌寵（homeplay-pet）
#   Contents/Resources/homeplay-receiver 接收器（登录自启的 LaunchAgent／桌宠重压时拉起）
#   Contents/Resources/                 SwiftPM 資源包（本地化字串）等
# 接收器刻意不放 Contents/MacOS：LaunchServices 會把 MacOS 裡的進程登記成整個 App（同一 bundle id），
# 接收器常駐時 `open HomePlay.app` 會被判「已在執行」而失敗（-600），桌寵就開不起來。
# Resources 裡的執行檔不參與 App 登記（lsappinfo 實測對照）。
# Info.plist 寫明各權限的用途說明：沒有這些，系統不會跳行事曆、自動化、藍牙、區域網路的授權。
# 最後 ad-hoc 簽名，讓權限記在這個 App 名下。
# 用法：tooling/make-app.sh [輸出路徑，預設 dist/HomePlay.app]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product homeplay-pet
swift build -c release --product homeplay-receiver

APP=${1:-dist/HomePlay.app}
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/homeplay-pet "$APP/Contents/MacOS/HomePlay"
cp .build/release/homeplay-receiver "$APP/Contents/Resources/homeplay-receiver"
for b in .build/release/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done
for l in assets/info-plist/*.lproj(N); do cp -R "$l" "$APP/Contents/Resources/"; done   # 權限彈窗的英/簡/繁說明
[[ -d identity ]] && cp -R identity "$APP/Contents/Resources/identity"   # 公開實驗身份隨包：別的 Mac 開箱即連
[[ -f assets/icon/AppIcon.icns ]] && cp assets/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # 圖示：晨昏漸層加一雙大眼
for i in assets/icon/CarPlayIcon-*.png(N); do cp "$i" "$APP/Contents/Resources/"; done   # CarPlay 主畫面上的 HomePlay 圖示（點它回到桌寵錶面）

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>HomePlay</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string><string>zh-Hant</string></array>
  <key>CFBundleDisplayName</key><string>HomePlay</string>
  <key>CFBundleIdentifier</key><string>me.aaronlau.homeplay</string>
  <key>CFBundleExecutable</key><string>HomePlay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string><string>zh-Hant</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 HomePlay</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Reads the current track and progress from Music or Spotify when you enable Mac Now Playing for the desk pet screen.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Shows your next event on the Modular face.</string>
  <key>NSCameraUsageDescription</key><string>Optionally turns the pet toward you and estimates room lighting. Frames are processed on this Mac and are never saved.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Pairs with your iPhone over Bluetooth to set up wireless CarPlay.</string>
  <key>NSMicrophoneUsageDescription</key><string>Uses the Mac's microphone only for Siri and phone calls in CarPlay.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Receives CarPlay video and audio from your iPhone over the local network.</string>
  <key>NSLocationUsageDescription</key><string>Uses your approximate location to show local weather on the Weather face.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Uses your approximate location to show local weather on the Weather face.</string>
  <key>NSBonjourServices</key><array><string>_airplay._tcp</string><string>_carplay-ctrl._tcp</string></array>
</dict>
</plist>
EOF

# 最後簽名：有 Developer ID Application 憑證就用它（安全時間戳＋Hardened Runtime，這是 Apple 公證的前提）；
# 沒有就退回 ad-hoc（自己能用，但不能公證）。
if ID=$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}'); [[ -n "$ID" ]]; then
  SIGN=(--force --sign "$ID" --timestamp --options runtime)
else
  echo "· 沒找到 Developer ID Application 憑證，退回 ad-hoc 簽名（不能公證）" >&2
  SIGN=(--force --sign - --timestamp=none)
fi
# Apple 的時間戳服務偶爾連不上（The timestamp service is not available）：重試幾次，別留下簽一半的 App
sign() { local i; for i in 1 2 3 4 5; do codesign "$@" && return 0; echo "· 簽名失敗，5 秒後重試（$i/5）" >&2; sleep 5; done; return 1; }
for b in "$APP/Contents/Resources"/*.bundle(N); do sign "${SIGN[@]}" "$b"; done
# 接收器单独签名也要带麦克风 entitlement（launchd 拉起的是它，不是 App 主进程）
sign "${SIGN[@]}" --entitlements tooling/HomePlay.entitlements "$APP/Contents/Resources/homeplay-receiver"
sign "${SIGN[@]}" --entitlements tooling/HomePlay.entitlements "$APP"
codesign --verify --strict --verbose=1 "$APP"
spctl -a -vv "$APP" 2>&1 || true
# 打包 zip 用 Info-ZIP 的 zip（cd 到輸出目錄、zip -qry）：它不存 xattr，壓縮包裡不會有 ._ AppleDouble 檔，
# 任何解壓工具解出來都一樣。ditto -c -k 會把 com.apple.provenance 存成 ._ 檔，而這個 xattr 在新系統上刪不掉。
echo "$APP"
