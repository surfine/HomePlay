#!/bin/zsh
# 2.0 Preview 頁的現拍素材：每種語言一套 1024² 螢幕平面圖（--screen-png）、兩張機身產品照（RealityKit）。
# 一律 --demo-official 示範資料（10:09、2026-04-01），SnapshotPrivacy 下不讀真的訊息、聯絡人與照片。
# 用法：先在上層 swift build -c release，再
#   scripts/render-preview.sh /tmp/hp-preview && python3 -I scripts/encode-preview.py /tmp/hp-preview
# 機器忙的時候 RealityKit 第一格要 20–60 s，所以每張都有 alarm 逾時。拍照視窗放在螢幕外（--at 30000,30000）。
B=${HOMEPLAY_PET:-${0:A:h}/../../.build/release/homeplay-pet}
O=${1:?output dir}
# 時區固定成示範天氣的城市（台北市）：世界錶面寫的是「目前時區」的城市，不讓拍出來的圖跟著拍照那台 Mac 的所在地
export TZ=Asia/Taipei
typeset -a J
for L in zh-Hant zh-Hans en; do
  D=$O/$L; mkdir -p $D
  shot() { local n=$1; shift; perl -e 'alarm 90; exec @ARGV' $B --size 1600 --at 30000,30000 --lang $L --demo-official "$@" --screen-png $D/$n.png >/dev/null 2>&1 || echo "FAIL $L $n"; }
  run() { shot "$@" & J+=($!); if (( ${#J} >= 4 )); then wait $J[1]; J=(${J[2,-1]}); fi }
  for s in island photos modular analog flow weather world calendar growth black system6 cluster; do run face-$s --style $s; done   # = FaceStyle.lineup
  for a in light dark clear tinted; do run home-$a --home --home-appearance $a; done
  run home-library --home --library
  run home-edit --home --home-edit
  run widget-gallery --home --widget-gallery
  run cc --home --control-center
  run la-compact --style photos --live-activity timer,music
  run la-expanded --style photos --live-activity-expanded music
  run app-weather-rain --app weather --demo-weather rain
  run app-timers --app timers --demo-timers
  run app-music --app music --demo-music nowplaying
  run app-messages-confirm --app messages --messages-demo confirm
  run app-facetime --app facetime --demo-facetime
  run app-home --app home --demo-home
  run app-recipe-step --app recipes --demo-recipe step:2
  run app-intercom --app intercom --demo-intercom
  run clio-listen --app cliotalk --cliotalk-demo listening
  run clio-answer --app cliotalk --cliotalk-demo answer
  run clio-confirm --app cliotalk --cliotalk-demo confirm
  run people-greet --style photos --people-demo
  wait
  # 機身產品照：同一個相機，螢幕換錶面或主畫面（首屏用錶面那張；主畫面那張是 make-og-pages.py 的分享卡片素材）
  for v in island home; do
    if [ $v = home ]; then X=(--home); else X=(--style island); fi
    perl -e 'alarm 150; exec @ARGV' $B --size 1400 --at 30000,30000 --near --product-shot --lang $L --demo-official $X --snapshot $D/prod-$v.png >/dev/null 2>&1 || echo "FAIL $L prod-$v"
  done
done
echo done
