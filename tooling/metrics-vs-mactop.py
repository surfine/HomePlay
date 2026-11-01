#!/usr/bin/env python3
"""metrics-vs-mactop：儀表資料層（D1）的讀值跟 mactop 對照（只用標準函式庫，python3 -I 執行）。

用法
  python3 -I tooling/metrics-vs-mactop.py [--ours .build/debug/homeplay-pet] [--count 3]
                                          [--mactop mactop] [--strict-missing]

  先跑 `<ours> --metrics-json N`，緊接著跑 `mactop --headless --count N -i 1000 --format json`，
  兩邊各自取平均（速率類跳過沒有差值的第一筆），印一張對照表。
  超出容差＝「差」；任何一項「差」就以 1 結束。我們讀不到（—）而 mactop 讀得到＝「缺」，
  B 層允許讀不到，所以預設不算失敗；加 --strict-missing 才算。

  加 --parallel 讓兩邊同時取樣。預設一前一後，兩邊不是同一時刻取樣，CPU、GPU、功率、速率本來就會跳，所以容差寬，只抓「算法錯了」等級的落差。
  mactop（MIT，metaspartan/mactop）不用 sudo；thermal_state 是在地化字串，這裡對應回 5 級。
"""

import argparse
import json
import subprocess
import sys

GB = 1e9


def run_lines(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if p.returncode != 0:
        sys.exit(f"執行失敗：{' '.join(cmd)}\n{p.stderr.strip()}")
    return p.stdout


def ours_cmd(exe, n):
    return [exe, "--metrics-json", str(n)]


def mactop_cmd(exe, n):
    return [exe, "--headless", "--count", str(n), "-i", "1000", "--format", "json"]


def parse_ours(out):
    return [json.loads(l) for l in out.splitlines() if l.strip().startswith("{")]


def parse_mactop(out):
    out = out.strip()
    try:
        d = json.loads(out)
        return d if isinstance(d, list) else [d]
    except json.JSONDecodeError:  # 有的版本逐行輸出
        return [json.loads(l) for l in out.splitlines() if l.strip()]


def g(d, *path):
    for k in path:
        if isinstance(d, dict):
            d = d.get(k)
        elif isinstance(d, list) and isinstance(k, int) and -len(d) <= k < len(d):
            d = d[k]
        else:
            return None
    return d


def mean(vals):
    v = [x for x in vals if isinstance(x, (int, float))]
    return sum(v) / len(v) if v else None


def cluster(s, letters):
    for c in s.get("clusters") or []:
        if (c.get("short") or c.get("name", "?")[:1]).upper() in letters:
            return c
    return None


THERMAL = {
    "nominal": 0, "normal": 0, "正常": 0,
    "moderate": 1, "fair": 1, "中等": 1,
    # 2026-10-29 實測：notify 原值 2（Heavy）時 mactop 印「偏高」，1 時印「中等」
    "heavy": 2, "serious": 2, "偏高": 2, "嚴重": 2, "严重": 2, "重度": 2, "高": 2,
    "trapping": 3, "critical": 3, "危急": 3, "臨界": 3, "临界": 3,
    "sleeping": 4, "睡眠": 4,
}


def thermal_level(v):
    if isinstance(v, (int, float)):
        return v
    return THERMAL.get(str(v).strip().lower()) if v is not None else None


def mode(vals):
    v = [x for x in vals if x is not None]
    return max(set(v), key=v.count) if v else None


# 名稱, 單位, 我們的取值, mactop 的取值, 容差判斷(ours, ref) -> bool, 是否為速率（跳過第一筆）
def rate_ok(a, b):
    # 速率很跳：只有兩邊都超過 1 MB/s 而且差 5 倍以上才算錯
    lo, hi = sorted([a, b])
    return hi < 1e6 or lo * 5 >= hi


def within(abs_tol, rel=0.0):
    return lambda a, b: abs(a - b) <= max(abs_tol, rel * abs(b))


# 定義不同、只列出不判定：我們讀實體碟（IOBlockStorageDriver），mactop 讀 APFS 卷宗；
# APFS 先記帳、實體碟晚一點才成批寫出，幾秒的窗裡寫入量本來就會錯開
INFO_ONLY = {"磁碟讀", "磁碟寫"}

METRICS = [
    ("CPU 使用率", "%", lambda s: s.get("cpuPercent"), lambda m: m.get("cpu_usage"), within(15), True),
    ("S/P 叢集頻率", "MHz", lambda s: g(cluster(s, "SP"), "mhz"), lambda m: g(m, "soc_metrics", "p_cluster_freq_mhz"), within(600, 0.3), True),
    ("S/P 叢集忙碌", "%", lambda s: g(cluster(s, "SP"), "activePercent"), lambda m: g(m, "soc_metrics", "p_cluster_active"), within(25), True),
    ("E 叢集頻率", "MHz", lambda s: g(cluster(s, "E"), "mhz"), lambda m: g(m, "soc_metrics", "e_cluster_freq_mhz"), within(600, 0.3), True),
    ("E 叢集忙碌", "%", lambda s: g(cluster(s, "E"), "activePercent"), lambda m: g(m, "soc_metrics", "e_cluster_active"), within(25), True),
    ("GPU 使用率", "%", lambda s: s.get("gpuPercent"), lambda m: g(m, "soc_metrics", "gpu_active"), within(25), True),
    ("GPU 頻率", "MHz", lambda s: s.get("gpuMHz"), lambda m: g(m, "soc_metrics", "gpu_freq_mhz"), within(300, 0.4), True),
    # mactop 的 system_power 是 PSTR 減掉 CPU/GPU/ANE/DRAM 元件和之後的「其餘」，整機 PSTR 在 total_power
    ("整機功率", "W", lambda s: g(s, "power", "systemW"), lambda m: g(m, "soc_metrics", "total_power"), within(3, 0.35), True),
    ("CPU 功率", "W", lambda s: g(s, "power", "cpuW"), lambda m: g(m, "soc_metrics", "cpu_power"), within(2, 0.5), True),
    ("GPU 功率", "W", lambda s: g(s, "power", "gpuW"), lambda m: g(m, "soc_metrics", "gpu_power"), within(2, 0.5), True),
    ("SoC 溫度", "°C", lambda s: s.get("socTempC"), lambda m: g(m, "soc_metrics", "soc_temp"), within(8), False),
    ("記憶體已用", "GB", lambda s: (g(s, "memory", "usedBytes") or None) and g(s, "memory", "usedBytes") / GB,
     lambda m: (g(m, "memory", "used") or 0) / GB or None, within(1.5), False),
    ("置換已用", "GB", lambda s: (lambda v: v / GB if v is not None else None)(g(s, "memory", "swapUsedBytes")),
     lambda m: (lambda v: v / GB if v is not None else None)(g(m, "memory", "swap_used")), within(0.5), False),
    ("記憶體壓力", "級", lambda s: g(s, "memory", "pressureLevel"), lambda m: g(m, "memory", "pressure_level"), within(0), False),
    ("電量", "%", lambda s: g(s, "battery", "percent"), lambda m: g(m, "battery", "percent") if g(m, "battery", "present") is not False else None, within(2), False),
    ("網路下載", "B/s", lambda s: s.get("netInBytesPerSec"), lambda m: g(m, "net_disk", "in_bytes_per_sec"), rate_ok, True),
    ("網路上傳", "B/s", lambda s: s.get("netOutBytesPerSec"), lambda m: g(m, "net_disk", "out_bytes_per_sec"), rate_ok, True),
    ("磁碟讀", "B/s", lambda s: s.get("diskReadBytesPerSec"), lambda m: (lambda v: v * 1024 if v is not None else None)(g(m, "net_disk", "read_kbytes_per_sec")), rate_ok, True),
    ("磁碟寫", "B/s", lambda s: s.get("diskWriteBytesPerSec"), lambda m: (lambda v: v * 1024 if v is not None else None)(g(m, "net_disk", "write_kbytes_per_sec")), rate_ok, True),
]


def fmt(v, unit):
    if v is None:
        return "—"
    if unit == "B/s":
        return f"{v / 1e6:.2f} MB/s"
    return f"{v:.1f}" if isinstance(v, float) else str(v)


def main():
    ap = argparse.ArgumentParser(description="儀表讀值跟 mactop 對照")
    ap.add_argument("--ours", default=".build/debug/homeplay-pet")
    ap.add_argument("--mactop", default="mactop")
    ap.add_argument("--count", type=int, default=3)
    ap.add_argument("--strict-missing", action="store_true")
    ap.add_argument("--sequential", action="store_true", help="一前一後跑（預設兩邊同時跑）")
    a = ap.parse_args()
    n = max(2, a.count)

    # 預設同時跑：一前一後的取樣窗不重疊，CPU、磁碟這類爆發性讀值每次都會對不上（2026-10-29 實測）
    if not a.sequential:
        # 同一段時間一起取樣，跳動大的指標（CPU、功率、速率）比較對得上；兩邊會互相多出一點負載
        ps = [subprocess.Popen(c, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
              for c in (ours_cmd(a.ours, n), mactop_cmd(a.mactop, n))]
        outs = [p.communicate(timeout=120)[0] for p in ps]
        ours, ref = parse_ours(outs[0]), parse_mactop(outs[1])
    else:
        ours = parse_ours(run_lines(ours_cmd(a.ours, n)))
        ref = parse_mactop(run_lines(mactop_cmd(a.mactop, n)))
    if not ours or not ref:
        sys.exit("沒有拿到讀值")

    rows, bad, missing = [], 0, 0
    for name, unit, fo, fm, ok, is_rate in METRICS:
        os_ = ours[1:] if is_rate and len(ours) > 1 else ours
        o = mean([fo(s) for s in os_])
        r = mean([fm(m) for m in ref])
        if r is None and o is None:
            st = "－"
        elif o is None:
            st = "缺"; missing += 1
        elif r is None:
            st = "只有我們"
        elif name in INFO_ONLY:
            st = "參考"
        elif ok(o, r):
            st = "OK"
        else:
            st = "差"; bad += 1
        rows.append((name, fmt(o, unit), fmt(r, unit), unit if unit != "B/s" else "", st))

    ot = mode([s.get("thermalPressure") for s in ours])
    rt = mode([thermal_level(m.get("thermal_state")) for m in ref])
    if rt is None and ref[-1].get("thermal_state") is not None:
        tst = "mactop 字串未知"
    elif ot is None:
        tst = "缺" if rt is not None else "－"; missing += rt is not None
    elif rt is None:
        tst = "只有我們"
    # 兩邊讀同一個 notify 鍵，必須同級；差一級剛好跨過警示燈門檻，不能放寬。
    # 取樣時間錯開造成的換級，只要有任一筆同級就算對上
    elif ot == rt or {s.get("thermalPressure") for s in ours} & {thermal_level(m.get("thermal_state")) for m in ref} - {None}:
        tst = "OK"
    else:
        tst = "差"; bad += 1
    rows.append(("熱壓力", fmt(ot, ""), f"{fmt(rt, '')}（{ref[-1].get('thermal_state')}）", "級", tst))

    w = [max(len(str(r[i])) for r in rows + [("指標", "我們", "mactop", "單位", "結果")]) for i in range(5)]
    for r in [("指標", "我們", "mactop", "單位", "結果")] + rows:
        print("  ".join(str(c).ljust(w[i]) for i, c in enumerate(r)))
    print(f"\n我們 {len(ours)} 筆、mactop {len(ref)} 筆；差 {bad} 項、缺 {missing} 項")
    sys.exit(1 if bad or (a.strict_missing and missing) else 0)


if __name__ == "__main__":
    main()
