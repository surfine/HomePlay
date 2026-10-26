#!/bin/zsh
# perf-probe.sh — homeplay-pet 效能／能效探針（Apple 晶片前後對照用）
#
# 每個狀態各跑 N 秒（預設 60；idle5min 量最後 60 秒，預設全程 300 秒），記：
#   CPU%（top -l 每秒取樣：平均／中位／p95／最大）、IDLEW（每秒閒置喚醒）、RSS。
# powermetrics 需要 root：sudo -n 拿不到就跳過，並在表頭註明（能效改用 IDLEW 當代理指標）。
# 電源狀態（pmset -g batt）記在表頭；電池模擬交給呼叫端（HOMEPLAY_BATTERY=1，程式內的診斷開關）。
#
# 狀態全部用 --demo-official（示範內容，不讀真資料）＋ HOMEPLAY_STATE_NAME 隔離：
# 不裝不踢使用者真正在跑的接收器。看中位數為準（使用者同時在用機器時，游標經過
# 桌寵會短暫拉高 CPU，中位數不受影響）。
#
# 用法：
#   tooling/perf-probe.sh [--binary PATH] [--out DIR] [--tag before] [--seconds 60]
#                        [--idle-seconds 300] [--states a,b,c] [--sample a,b]
# 輸出：<out>/summary.md（也印到 stdout）、<out>/<state>.{log,top}、<out>/<state>.sample.txt

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/release/homeplay-pet"
OUT="$ROOT/.build/perf/$(date +%Y%m%d-%H%M%S)"
TAG=""
MEASURE=60
IDLE_SECONDS=300
STATES=""
SAMPLE_STATES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary) BIN="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --seconds) MEASURE="$2"; shift 2 ;;
    --idle-seconds) IDLE_SECONDS="$2"; shift 2 ;;
    --states) STATES="$2"; shift 2 ;;
    --sample) SAMPLE_STATES="$2"; shift 2 ;;
    *) echo "perf-probe: 不认参数 $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$OUT"
[[ -n "$STATES" ]] || STATES="face-island,face-photos,face-modular,face-typograph,face-flow,face-weather,face-calendar,face-system6,face-growth,face-black,home,library,control-center,weather-app,music,live-activity,idle5min"

# 狀態 → 旗標（--demo-official 另外統一加）
typeset -A FLAGS
FLAGS=(
  face-island     "--style island"
  face-photos     "--style photos"
  face-modular    "--style modular"
  face-typograph  "--style analog"
  face-flow       "--style flow"
  face-weather    "--style weather"
  face-calendar   "--style calendar"
  face-system6    "--style system6"
  face-growth     "--style growth"
  face-black      "--style black"
  home            "--home"
  library         "--library"
  control-center  "--control-center"
  weather-app     "--app weather"
  music           "--music 2SIDED|Arlo Parks|0.5"
  live-activity   "--live-activity timer,music"
  spin            "--connecting"   # 連線過場一直在轉：持續 60fps 的狀態，驗證「用電池自動降幀」用
  idle5min        ""
)

# ---- 隔離狀態目錄預植 ----
# 全新狀態目錄會被當成「首次使用」：自動進配對引導（60fps 過場動畫）甚至拉起隔離接收器。
# 預先放一份 wireless.json（ignoredPhones 非空＝「忘記過手機」）：不自動進場、也不自動掛接收器。
# 另外全程 HOMEPLAY_PERF_PROBE=1（程式內的量測防護）：就算有人點到量測寵物的「使用 iPhone」，
# 它也連不上真接收器——第一次量基線時就發生過：連上後收真 CarPlay 影片（+25% CPU）、
# 還把 rehearsal LaunchAgent 裝了起來。
STATE_DIR="$HOME/Library/Application Support/zcode-perf-probe"
mkdir -p "$STATE_DIR"
cat > "$STATE_DIR/wireless.json" <<'EOF'
{
  "phone" : "",
  "ssid" : "",
  "passphrase" : "",
  "size" : "1088x1088",
  "port" : 8788,
  "source" : "auto",
  "ignoredPhones" : [
    "zcode-perf-probe"
  ]
}
EOF
chmod 600 "$STATE_DIR/wireless.json"

# ---- 表頭資訊 ----
{
  echo "# perf-probe ${TAG:+（$TAG）} — $(date '+%Y-%m-%d %H:%M')"
  echo ""
  echo "- 機器：$(sysctl -n machdep.cpu.brand_string)（$(sysctl -n hw.model)），macOS $(sw_vers -productVersion)"
  echo "- 二進位：$BIN（sha256 $(shasum -a 256 "$BIN" | cut -c1-16)…）"
  echo "- 電源：$(pmset -g batt | head -1 | sed 's/^Now drawing from //')"
  if sudo -n powermetrics -h >/dev/null 2>&1; then
    echo "- powermetrics：sudo -n 可用"
  else
    echo "- powermetrics：**跳過**（sudo -n 需要密碼——依任務指示跳過並註明；能效改用 IDLEW 每秒閒置喚醒當代理指標）"
  fi
  echo "- 取樣：top -l 每秒 1 次、甩掉前 2 筆（top 首筆差分不可信＋啟動尖峰）；看 CPU 中位數"
  echo ""
} | tee "$OUT/summary.md"

echo "| 狀態 | 秒 | CPU 平均% | CPU 中位% | CPU p95% | IDLEW/s | RSS MB | 備註 |" | tee -a "$OUT/summary.md"
echo "|---|---|---|---|---|---|---|---|" | tee -a "$OUT/summary.md"

for st in ${(s:,:)STATES}; do
  flags="${FLAGS[$st]:-}"
  if [[ "$st" == "idle5min" ]]; then
    measure=$(( MEASURE < IDLE_SECONDS ? MEASURE : IDLE_SECONDS ))
    settle=$(( IDLE_SECONDS - measure ))   # 等 90 秒海報模式進場後才開始量
  else
    measure="$MEASURE"
    settle=10
  fi

  echo "perf-probe: $st（穩定 ${settle}s 後量 ${measure}s）…" >&2
  # --at 48,64：視窗放左下角，離使用者平常工作的地方遠一點（有人靠近＝追蹤游標的 60fps，量測會被拉高）
  HOMEPLAY_PERF_PROBE=1 HOMEPLAY_STATE_NAME=zcode-perf-probe "$BIN" --demo-official --at 48,64 ${=flags} > "$OUT/$st.log" 2>&1 &
  pid=$!
  sleep "$settle"

  note=""
  if ! kill -0 "$pid" 2>/dev/null; then
    note="進程提前退出：$(tail -2 "$OUT/$st.log" | tr '\n' ' ')"
    echo "| $st | 0 | - | - | - | - | - | $note |" | tee -a "$OUT/summary.md"
    continue
  fi
  if [[ -n "$SAMPLE_STATES" ]] && [[ ",$SAMPLE_STATES," == *",$st,"* ]]; then
    sample "$pid" 5 -file "$OUT/$st.sample.txt" -mayDie 2>/dev/null || true
    note="sample 5s 已存"
  fi

  top -l $(( measure + 2 )) -s 1 -pid "$pid" -stats pid,cpu,idlew,mem 2>/dev/null \
    | awk -v pid="$pid" '$1 == pid { print $2, $3, $4 }' > "$OUT/$st.top" || true
  rss=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{ printf "%.0f", $1 / 1024 }' || echo 0)
  kill "$pid" 2>/dev/null || true
  sleep 1
  kill -9 "$pid" 2>/dev/null || true

  # 統計：甩掉前 2 筆（首筆差分＋啟動尾），其餘每秒一筆
  tail -n +3 "$OUT/$st.top" > "$OUT/$st.dat"
  cpu_avg=$(awk '{ s += $1; n++ } END { if (n) printf "%.2f", s / n; else print "0" }' "$OUT/$st.dat")
  cpu_med=$(awk '{ print $1 }' "$OUT/$st.dat" | sort -n | awk '{ a[NR] = $1 } END { if (NR) printf "%.2f", a[int((NR + 1) / 2)] ; else print "0" }')
  cpu_p95=$(awk '{ print $1 }' "$OUT/$st.dat" | sort -n | awk '{ a[NR] = $1 } END { if (NR) printf "%.2f", a[int(NR * 0.95 + 0.5)] ; else print "0" }')
  idlew_avg=$(awk '{ s += $2; n++ } END { if (n) printf "%.1f", s / n; else print "0" }' "$OUT/$st.dat")

  grep -q "poster: idle" "$OUT/$st.log" && note="${note:+$note；}海報模式已進場"
  echo "| $st | $measure | $cpu_avg | $cpu_med | $cpu_p95 | $idlew_avg | $rss | $note |" | tee -a "$OUT/summary.md"
done

echo "" | tee -a "$OUT/summary.md"
echo "完整輸出在 $OUT" >&2
