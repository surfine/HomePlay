#!/bin/zsh
# 首次配對演練：用另一份「全新安裝」的 HomePlay 跑一遍第一次配對，不碰平常那份。
#   start    收起平常的 HomePlay 與它的接收器（LaunchAgent 只卸載不刪），打開演練版
#   restore  收起演練版，把平常那份原樣拉回來（一條指令回到日常）
#   reset    清空演練版的狀態、偏好與權限（下一次演練又是全新安裝）；不碰平常那份
#   status   看現在跑的是哪一份
# 演練版：HOMEPLAY_VARIANT=rehearsal zsh tooling/make-app.sh（→ dist/HomePlay Rehearsal.app）
# 它用另一個 bundle id（偏好、相機／藍牙／定位權限全新）、狀態放 ~/Library/Application Support/HomePlay Rehearsal、
# LaunchAgent 標籤 me.aaron.homeplay.receiver.rehearsal。藍牙配對是系統層級的，本腳本不碰；
# 要演練「藍牙第一次配對」得自己在 iPhone 與 Mac 上忘記對方（步驟見 docs/first-pair-test.md）。
set -euo pipefail
cd "$(dirname "$0")/.."

UID_=$(id -u)
REAL_ID=me.aaronlau.homeplay
REAL_LABEL=me.aaron.homeplay.receiver
REAL_PLIST=~/Library/LaunchAgents/$REAL_LABEL.plist
REAL_APP=${HOMEPLAY_REAL_APP:-/Applications/HomePlay.app}
REH_ID=me.aaronlau.homeplay.rehearsal
REH_LABEL=me.aaron.homeplay.receiver.rehearsal
REH_PLIST=~/Library/LaunchAgents/$REH_LABEL.plist
REH_APP=${HOMEPLAY_REHEARSAL_APP:-$PWD/dist/HomePlay Rehearsal.app}
REH_STATE=~/Library/Application\ Support/HomePlay\ Rehearsal

quit_app() { osascript -e "tell application id \"$1\" to quit" >/dev/null 2>&1 || true; }
loaded() { launchctl print "gui/$UID_/$1" >/dev/null 2>&1; }
wait_gone() { local i; for i in {1..20}; do pgrep -f "$1" >/dev/null || return 0; sleep 0.25; done; pkill -f "$1" || true; }

case ${1:-status} in
start)
  [[ -d "$REH_APP" ]] || { echo "找不到 $REH_APP：先 HOMEPLAY_VARIANT=rehearsal zsh tooling/make-app.sh" >&2; exit 1; }
  quit_app $REAL_ID
  if loaded $REAL_LABEL; then launchctl bootout "gui/$UID_/$REAL_LABEL" || true; fi
  wait_gone "$REAL_APP/Contents/Resources/homeplay-receiver"
  open "$REH_APP"
  echo "演練版已開（狀態：$REH_STATE）。結束：zsh tooling/first-pair-rehearsal.sh restore" ;;
restore)
  quit_app $REH_ID
  if loaded $REH_LABEL; then launchctl bootout "gui/$UID_/$REH_LABEL" || true; fi
  rm -f "$REH_PLIST"
  wait_gone "$REH_APP/Contents/Resources/homeplay-receiver"
  if [[ -f "$REAL_PLIST" ]] && ! loaded $REAL_LABEL; then launchctl bootstrap "gui/$UID_" "$REAL_PLIST"; fi
  open -b $REAL_ID
  echo "已回到平常的 HomePlay。" ;;
reset)
  if pgrep -f "$REH_APP/Contents" >/dev/null; then echo "演練版還在跑：先 restore" >&2; exit 1; fi
  [[ "$REH_STATE" == */Application\ Support/HomePlay\ Rehearsal ]] || { echo "狀態路徑不對：$REH_STATE" >&2; exit 1; }
  rm -rf "$REH_STATE"
  defaults delete $REH_ID >/dev/null 2>&1 || true
  tccutil reset All $REH_ID >/dev/null 2>&1 || true
  echo "演練版的狀態、偏好、權限已清空（平常那份沒動）。" ;;
status)
  pgrep -f "$REAL_APP/Contents/MacOS" >/dev/null && echo "平常的 HomePlay：執行中" || echo "平常的 HomePlay：沒在跑"
  loaded $REAL_LABEL && echo "平常的接收器 LaunchAgent：已載入" || echo "平常的接收器 LaunchAgent：未載入"
  pgrep -f "$REH_APP/Contents" >/dev/null && echo "演練版：執行中" || echo "演練版：沒在跑"
  loaded $REH_LABEL && echo "演練版 LaunchAgent：已載入" || true ;;
*) echo "用法：$0 start|restore|reset|status" >&2; exit 2 ;;
esac
