#!/usr/bin/env python3
"""perf-pixdiff：前後 --screen-png 的逐像素對照（外觀不變的驗收用）。

用法：
  python3 tooling/perf-pixdiff.py BEFORE_DIR AFTER_DIR [--thresh 8]

兩個資料夾裡同名的 PNG 一對一比（都是 1024² 的螢幕平面圖）：
- 不同像素比例（任一通道差 > thresh 才算；thresh 預設 8，吸收字體微渲染與 PNG 編碼的抖動）
- 全圖最大通道差、差異像素的平均通道差
- 差異比例 > 0.5% 的圖另存 *_diff.png（放大差異位置，紅＝不同）

動畫時間點本來就會造成的差異（計時器秒數、天氣資料更新）請人工看 diff 圼再判斷。
只在本機用；只需要 Pillow。
"""

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageChops


def compare(before: Path, after: Path, thresh: int) -> dict:
    a = Image.open(before).convert("RGB")
    b = Image.open(after).convert("RGB")
    if a.size != b.size:
        b = b.resize(a.size)
    pa, pb = a.load(), b.load()
    w, h = a.size
    diff = ImageChops.difference(a, b).load()
    changed = 0
    maxd = 0
    total = 0.0
    mask = Image.new("RGB", a.size, (0, 0, 0))
    pm = mask.load()
    for y in range(h):
        for x in range(w):
            r, g, bb = diff[x, y]
            d = max(r, g, bb)
            if d > maxd:
                maxd = d
            if d > thresh:
                changed += 1
                total += d
                pm[x, y] = (255, 0, 0)
    n = w * h
    return {"changed": changed, "frac": changed / n, "maxd": maxd,
            "avgd": (total / changed) if changed else 0.0, "mask": mask}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("before", type=Path)
    ap.add_argument("after", type=Path)
    ap.add_argument("--thresh", type=int, default=8)
    ap.add_argument("--save-frac", type=float, default=0.005, help="差異比例超過這個值才存 diff 圖")
    args = ap.parse_args()

    names = sorted(p.name for p in args.before.glob("*.png"))
    if not names:
        print(f"perf-pixdiff：{args.before} 裡沒有 PNG", file=sys.stderr)
        return 2
    print(f"| 畫面 | 不同像素比例 | 最大通道差 | 差異平均 | 判定 |")
    print(f"|---|---|---|---|---|")
    bad = 0
    for name in names:
        fb, fa = args.before / name, args.after / name
        if not fa.exists():
            print(f"| {name} | — | — | — | 後測缺圖 |")
            bad += 1
            continue
        r = compare(fb, fa, args.thresh)
        ok = r["frac"] <= 0.005 and r["maxd"] <= 40
        if not ok:
            bad += 1
        if r["frac"] > args.save_frac:
            bg = Image.open(fb).convert("RGB")
            # 差異位置一目了然：原圖壓暗，紅色標出不同的像素
            dark = Image.eval(bg, lambda v: v // 3)
            out = Image.composite(Image.new("RGB", bg.size, (255, 0, 0)), dark, r["mask"].convert("L"))
            out.save(args.after / name.replace(".png", "_diff.png"))
        print(f"| {name} | {r['frac']*100:.3f}% | {r['maxd']} | {r['avgd']:.1f} | {'同' if ok else '不同（看 diff 圖）'} |")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
