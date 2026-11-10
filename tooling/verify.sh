#!/bin/zsh
# 裝機前閘門（docs/plans/regression-checklist.md）：全綠才許 make-app。
# 用法：tooling/verify.sh [二進位路徑]；預設 .build/release/homeplay-pet
BIN="${1:-.build/release/homeplay-pet}"; OUT="$(mktemp -d)"; BAD=0
say() { print "$1"; }
gate() { if eval "$2" >/dev/null 2>&1; then say "✓ $1"; else say "✗ $1"; BAD=1; fi; }

gate "build" "swift build -c release --product homeplay-pet"
gate "selftest 0 FAIL" "$BIN --selftest 2>&1 | grep -q 'selftest OK'"
gate "本地化三語齊全" "python3 tooling/check-localizable.py | grep -q '✓'"

# 逐面快照（B 級：產圖供人眼比對）＋計時預算（A 級：median ≤ 20ms）
for s in island photos modular analog flow pocket growth system6 weather world calendar embossed black cluster; do
  ms=$(HOMEPLAY_FRAMES_TIME=1 $BIN --era 2026 --style $s --time 10:09 --screen-png "$OUT/$s.png" --frames 12 2>&1 | grep -oE "median [0-9.]+" | grep -oE "[0-9.]+")
  ls $OUT/$s*.png >/dev/null 2>&1 || { say "✗ 快照 $s 沒出圖"; BAD=1; }
  if [ -n "$ms" ]; then awk -v v="$ms" -v n="$s" 'BEGIN { exit !(v <= 20) }' && say "✓ $s ${ms}ms" || { say "✗ $s ${ms}ms 超預算 20ms"; BAD=1; }
  else say "✗ $s 沒量到時間"; BAD=1; fi
done
say "快照目錄：$OUT（膠囊帶／底緣／圓角對照請用 tooling/concentric-overlay.py）"
exit $BAD
