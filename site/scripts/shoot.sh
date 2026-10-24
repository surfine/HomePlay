#!/bin/zsh
# 用 homeplay-pet 本身拍官網素材：shoot.sh <輸出.png> [homeplay-pet 參數…]
# 只開一扇窗、放在螢幕外（不會被正在用桌寵的人點到），拍完即關；需要先 swift build -c release。
# SHOOT_GLANCE／SHOOT_BLINK：同一格畫面再拍「瞄一眼」「閉眼」，給官網做疊圖動畫。
set -e
out=$1; shift
bin=${HOMEPLAY_PET:-$(cd "$(dirname $0)/../.." && pwd)/.build/release/homeplay-pet}
extra=()
[[ -n "$SHOOT_GLANCE" ]] && extra+=(--snapshot-glance "$SHOOT_GLANCE")
[[ -n "$SHOOT_BLINK" ]] && extra+=(--snapshot-blink "$SHOOT_BLINK")
for p in "$out" "$SHOOT_GLANCE" "$SHOOT_BLINK"; do [[ -n "$p" ]] && rm -f "$p"; done
"$bin" --size 900 --at 30000,30000 "$@" "${extra[@]}" --snapshot "$out" >"${SHOOT_LOG:-/dev/null}" 2>&1 &
pid=$!
for i in {1..120}; do [[ -s "$out" ]] && break; sleep 0.5; done   # 機器忙時 RealityKit 出第一張圖可能超過 20 秒
# 主圖先出來，兩張疊圖再各晚 0.12 s；等它們落盤再關窗
for i in {1..50}; do
  [[ -z "$SHOOT_GLANCE" || -s "$SHOOT_GLANCE" ]] && [[ -z "$SHOOT_BLINK" || -s "$SHOOT_BLINK" ]] && break
  sleep 0.2
done
sleep 0.2; kill $pid 2>/dev/null || true
[[ -s "$out" ]] || { echo "shoot failed: $out" >&2; exit 1; }
[[ -z "$SHOOT_GLANCE" || -s "$SHOOT_GLANCE" ]] || { echo "glance shoot failed: $SHOOT_GLANCE" >&2; exit 1; }
[[ -z "$SHOOT_BLINK" || -s "$SHOOT_BLINK" ]] || { echo "blink shoot failed: $SHOOT_BLINK" >&2; exit 1; }
