#!/usr/bin/env python3
"""同心圓角參考弧疊圖（圓角同心稽核用，2026-11-07）。

用法：python3 tooling/concentric-overlay.py in.png out.png [--insets 8,16,24,...] [--rect x,y,w,h ...]

在快照上畫出「螢幕圓角往內縮 N px」的同心參考框：位置＝螢幕往內 N、半徑＝R − N（R＝Screen.cornerRadius），
形狀跟 Swift 的 continuousRoundedRect 同一組連續圓角係數。貼邊容器的角應該正好貼在某一條參考弧上；
--rect 額外把指定容器框（只畫角，1024 畫布座標、左上原點）的 inset 標在角旁邊。

只依賴 Pillow；畫布 1024 × 1024（Screen.side）。
"""
import argparse
import sys

from PIL import Image, ImageDraw

SIDE = 1024.0
BODY_DIAG = 0.0398                       # CornerFit.bodyDiag（只讀鏡射）
R = BODY_DIAG * SIDE / 0.29438           # Screen.cornerRadius ≈ 138.4
MINIMUM = 12.0                           # HPTokens.Radius.concentric 的 minimum
K = 1.52866483                           # continuousRoundedRect 的角延伸係數
DEFAULT_INSETS = [8, 16, 24, 32, 48, 56, 64, 80, 96, 112]


def _cubic(p0, p1, p2, p3, n=16):
    out = []
    for i in range(1, n + 1):
        t = i / n
        u = 1 - t
        out.append((u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0],
                    u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1]))
    return out


def continuous_rounded_rect(x0, y0, x1, y1, radius):
    """回傳折線點（照 ScreenGeometry.swift continuousRoundedRect 的係數）。"""
    r = max(0.0, min(radius, min(x1 - x0, y1 - y0) / 2 / K))
    if r <= 0.5:
        return [(x0, y0), (x1, y0), (x1, y1), (x0, y1), (x0, y0)]
    tr = lambda a, b: (x1 - a * r, y0 + b * r)
    br = lambda a, b: (x1 - a * r, y1 - b * r)
    bl = lambda a, b: (x0 + a * r, y1 - b * r)
    tl = lambda a, b: (x0 + a * r, y0 + b * r)
    pts = [tl(K, 0), tr(K, 0)]

    def corner(f):
        pts.extend(_cubic(pts[-1], f(1.08849323, 0), f(0.86840689, 0), f(0.66993427, 0.06549600)))
        pts.append(f(0.63149399, 0.07491100))
        pts.extend(_cubic(pts[-1], f(0.39518276, 0.15435844), f(0.15435743, 0.39518377), f(0.07491176, 0.63149399)))
        pts.extend(_cubic(pts[-1], f(0, 0.86840701), f(0, 1.08849299), f(0, K)))

    corner(lambda a, b: tr(a, b))
    pts.append(br(0, K))
    corner(lambda a, b: br(b, a))
    pts.append(bl(K, 0))
    corner(lambda a, b: bl(a, b))
    pts.append(tl(0, K))
    corner(lambda a, b: tl(b, a))
    pts.append(pts[0])
    return pts


def color(i):
    palette = [(255, 70, 70), (255, 160, 40), (250, 230, 60), (90, 230, 90), (60, 210, 255),
               (110, 140, 255), (200, 110, 255), (255, 110, 200), (255, 255, 255), (160, 160, 160)]
    return palette[i % len(palette)]


def overlay(src, insets, rects, scale):
    img = src.convert("RGBA")
    ov = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    for i, n in enumerate(insets):
        rad = max(MINIMUM, R - n)
        pts = continuous_rounded_rect(n, n, SIDE - n, SIDE - n, rad)
        c = color(i)
        d.line([(x * scale, y * scale) for x, y in pts], fill=c + (215,), width=max(2, int(2 * scale)))
        # 標籤放在左上角 45° 位置附近
        lx, ly = (n + rad * 0.29438) * scale + 4, (n + rad * 0.29438) * scale + 4
        d.rectangle([lx - 1, ly - 1, lx + 22 * scale, ly + 11 * scale], fill=(0, 0, 0, 150))
        d.text((lx + 1, ly), f"{n}", fill=c + (255,))
    for (x, y, w, h) in rects:
        edge = min(x, y, SIDE - x - w, SIDE - y - h)
        exp = max(MINIMUM, R - edge)
        pts = continuous_rounded_rect(x, y, x + w, y + h, exp)
        d.line([(px * scale, py * scale) for px, py in pts], fill=(0, 255, 200, 230), width=max(1, int(scale)))
        d.text((x * scale + 6, y * scale + 6), f"inset {edge:.0f} -> r {exp:.1f}", fill=(0, 255, 200, 255))
    img.alpha_composite(ov)
    return img


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--insets", default=",".join(map(str, DEFAULT_INSETS)), help="參考弧的內縮量（逗號分隔）")
    ap.add_argument("--rect", action="append", default=[], help="容器框 x,y,w,h（1024 座標）：畫出它應有的同心外形")
    a = ap.parse_args()
    src = Image.open(a.input)
    if src.size[0] != src.size[1]:
        print(f"warning: 輸入不是正方形（{src.size}）", file=sys.stderr)
    scale = src.size[0] / SIDE
    insets = [float(v) for v in a.insets.split(",") if v.strip()]
    rects = [tuple(float(v) for v in s.split(",")) for s in a.rect]
    overlay(src, insets, rects, scale).convert("RGB").save(a.output, "PNG")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
