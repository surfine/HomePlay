#!/bin/sh
# 金幀哨兵：12 面 + 關鍵狀態逐像素比對（回歸防線 WP5）
# 用法：tooling/golden.sh            # 比對，沒有基準就建立
#       tooling/golden.sh --update   # 重新建立基準（改面之後才用，並在 commit 說明原因）
set -e
cd "$(dirname "$0")/.."
BIN=.build/release/homeplay-pet
BASE=tooling/golden/base
TMP=$(mktemp -d)
DIFF=.build/imgdiff
[ -x "$DIFF" ] || { echo "編譯 imgdiff…"; swiftc -O -parse-as-library tooling/imgdiff.swift -o "$DIFF"; }
# flow／world 目前每次重畫都不同（動畫相位、星點未凍結），先排除；修成可重現後再納入
FACES="island photos modular analog weather calendar growth black system6 cluster"
FAIL=0
UPD="$1"
mkdir -p "$BASE"
for f in $FACES; do
  # 日期與「小時」都要固定：行事曆/陪伴跟著系統日期，島/Flow 等面的底色跟著當下小時（夜裡是暗色），
  # 只凍日期不凍小時的話，金幀到了晚上就會整片變暗而 FAIL（2026-11-09 實際踩到）。
  HOMEPLAY_DATE=2026-04-01 "$BIN" --demo-official --era 2026 --style "$f" --time 10:09 --hour 10 --screen-png "$TMP/$f.png" >/dev/null 2>&1
  sips -Z 512 "$TMP/$f.png" --out "$TMP/$f.png" >/dev/null 2>&1
  if [ "$1" = "--update" ] || [ ! -f "$BASE/$f.png" ]; then
    cp "$TMP/$f.png" "$BASE/$f.png"; echo "BASE  $f"
  else
    printf '%-9s ' "$f"
    if ! "$DIFF" "$BASE/$f.png" "$TMP/$f.png" 0.02; then FAIL=1; fi
  fi
done

# 外殼頁（決定性已驗：連續兩次 mean=0）：主畫面、控制中心
for pg in home cc; do
  if [ "$pg" = home ]; then set -- --home --demo-official; else set -- --control-center --demo-official --style black; fi
  # 控制中心沒有 --style 時會沿用「上次選的錶面」當背景色；而且背景是現場錶面的模糊快照——
  # 島的壁紙會隨時間漂，兩跑就差 13%（2026-11-09 實測）。改用黑錶面（靜態）當背景，金幀才可重現。
  HOMEPLAY_DATE=2026-04-01 "$BIN" "$@" --time 10:09 --hour 10 --screen-png "$TMP/pg_$pg.png" >/dev/null 2>&1
  sips -Z 512 "$TMP/pg_$pg.png" --out "$TMP/pg_$pg.png" >/dev/null 2>&1
  if [ "$UPD" = "--update" ] || [ ! -f "$BASE/pg_$pg.png" ]; then
    cp "$TMP/pg_$pg.png" "$BASE/pg_$pg.png"; echo "BASE  page:$pg"
  else
    printf '%-9s ' "page:$pg"
    if ! "$DIFF" "$BASE/pg_$pg.png" "$TMP/pg_$pg.png" 0.02; then FAIL=1; fi
  fi
done

rm -rf "$TMP"
[ "$FAIL" = 0 ] && echo "金幀：全部通過" || { echo "金幀：有漂移，看上面 FAIL 的面"; exit 1; }
