#!/bin/zsh
# CarPlay 满版实验台（路径 A：改显示声明，看 iPhone 原生怎么排）。
#
# 用法：把 iPhone 带在身边，跑  zsh tooling/display-lab.sh
# 每一档会：设环境变量 → 启动桌宠 → 你重按连接、等画面出现 → 回到终端按回车
#          → 自动截屏 + 收日志 → 下一档。中途想跳过某档，直接回车即可。
#
# 结果：/tmp/homeplay-display-lab/log.txt（声明 + VIDEO_CONFIG 摘要）
#       /tmp/homeplay-display-lab/<档位>.png（连接后截屏，比手机拍照准）
set -u
cd "$(dirname "$0")/.."
LAB=/tmp/homeplay-display-lab
mkdir -p "$LAB"
LOG="$LAB/log.txt"
PET=/Applications/HomePlay.app/Contents/MacOS/HomePlay
[[ -x $PET ]] || { echo "找不到 $PET（先装好 HomePlay.app）"; exit 1 }

cleanup() { pkill -x HomePlay 2>/dev/null; }
trap cleanup EXIT INT TERM

run() {  # run <档位> [环境变量...]
  local label=$1; shift
  echo "\n════════ 档位 $label  env: $* ════════" | tee -a "$LOG"
  pkill -x HomePlay 2>/dev/null; sleep 1
  if (( $# )); then env "$@" "$PET" >>"$LOG" 2>&1 & else "$PET" >>"$LOG" 2>&1 & fi
  echo "  桌宠已启动（$*）。现在重按它连接 CarPlay，主屏出来后回到这里按回车（跳过也直接回车）"
  read -r "?  > "
  screencapture -x "$LAB/$label.png" 2>/dev/null && echo "  已截屏 $LAB/$label.png" | tee -a "$LOG"
  pkill -x HomePlay 2>/dev/null; sleep 1
}

echo "实验开始 $(date '+%H:%M:%S')，共 5 档，每档约半分钟" | tee -a "$LOG"
run base                                  # 基线：1088×1088，safe 内缩 36
run safe0      HOMEPLAY_SAFE_INSET=0      # safe area 贴满 view area
run phys180    HOMEPLAY_PHYS_MM=180       # 声称 180mm 大屏
run portrait   HOMEPLAY_DISPLAY_W=900 HOMEPLAY_DISPLAY_H=1200   # iOS 原生 3:4 竖屏
run wide       HOMEPLAY_DISPLAY_W=800 HOMEPLAY_DISPLAY_H=480    # iOS 原生 5:3 横屏（对照组）

echo "\n════════ 摘要 ════════"
grep -E "display viewArea|VIDEO_CONFIG|档位" "$LOG" | tail -30
echo "\n完整日志：$LOG；截屏在 $LAB/。跑完告诉 Aaron 就行，他自己会读。"
