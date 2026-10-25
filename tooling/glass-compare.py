#!/usr/bin/env python3
"""glass-compare：玻璃校準台的逐像素比對（真的 NSGlassEffectView 對我們的 HPGlass／SystemGlass）。

用法
  .build/release/homeplay-pet --glass-calibrate DIR            # 先拍真值、畫我們的（DIR/truth-*.png、ours-*.png、shapes.json）
  uv run --with numpy --with pillow --with matplotlib python tooling/glass-compare.py DIR [--label before]

輸出（都在 DIR）
  report-<label>.json   每個 外觀×背景×形狀 的數字
  report-<label>.md     表：ΔE（CIEDE2000）形狀內平均／p95、核心／邊帶、邊緣剖面位移與殘差、亮邊、外陰影、細節（模糊）、彩度
  dE-<label>-<tag>.png  真值｜我們｜ΔE 熱圖（0–10）
  prof-<label>-<tag>.png 邊緣剖面（每個形狀左緣橫切、上緣縱切的 L*，實線真值、虛線我們）

指標
  dE_in      形狀內（向內縮 2 px）平均 ΔE2000；目標 ≤ 2
  dE_band    邊帶（形狀內 0–24 px）平均；dE_core 其餘
  shift      邊緣剖面（-16…+40 px）上，把我們的剖面平移多少能最貼近真值（px，正＝我們的特徵太靠外）；目標 |shift| ≤ 1
  rms        平移後的 L* 殘差
  rimT/rimO  緣上 -3…+6 px 內 L* 對背景的最大偏差（真值／我們）：亮邊或暗邊
  shadowT/O  形狀外 2–30 px 對原背景的 L* 平均差（外陰影）
  detailT/O  形狀核心的高頻量（L* 減 5 px 方框模糊後的標準差）：越小越糊
  chromaT/O  形狀內平均 C*
"""
import argparse
import json
import math
import os

import numpy as np
from PIL import Image

LOOKS = ["regular-light", "clear-light", "regular-dark", "clear-dark"]
BGS = ["photo", "busy", "white", "black", "color"]


def load(p):
    return np.asarray(Image.open(p).convert("RGB"), dtype=np.float64) / 255.0


def srgb_to_lab(rgb):
    c = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    m = np.array([[0.4124564, 0.3575761, 0.1804375], [0.2126729, 0.7151522, 0.0721750], [0.0193339, 0.1191920, 0.9503041]])
    xyz = c @ m.T
    xyz /= np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > (6 / 29) ** 3, np.cbrt(xyz), xyz / (3 * (6 / 29) ** 2) + 4 / 29)
    L = 116 * f[..., 1] - 16
    a = 500 * (f[..., 0] - f[..., 1])
    b = 200 * (f[..., 1] - f[..., 2])
    return np.stack([L, a, b], -1)


def de2000(lab1, lab2):
    L1, a1, b1 = lab1[..., 0], lab1[..., 1], lab1[..., 2]
    L2, a2, b2 = lab2[..., 0], lab2[..., 1], lab2[..., 2]
    C1 = np.hypot(a1, b1); C2 = np.hypot(a2, b2)
    Cm = (C1 + C2) / 2
    G = 0.5 * (1 - np.sqrt(Cm ** 7 / (Cm ** 7 + 25 ** 7)))
    a1p = (1 + G) * a1; a2p = (1 + G) * a2
    C1p = np.hypot(a1p, b1); C2p = np.hypot(a2p, b2)
    h1p = np.degrees(np.arctan2(b1, a1p)) % 360; h2p = np.degrees(np.arctan2(b2, a2p)) % 360
    dLp = L2 - L1; dCp = C2p - C1p
    dhp = h2p - h1p
    dhp = np.where(dhp > 180, dhp - 360, dhp); dhp = np.where(dhp < -180, dhp + 360, dhp)
    dhp = np.where(C1p * C2p == 0, 0, dhp)
    dHp = 2 * np.sqrt(C1p * C2p) * np.sin(np.radians(dhp) / 2)
    Lpm = (L1 + L2) / 2; Cpm = (C1p + C2p) / 2
    hsum = h1p + h2p
    hpm = np.where(np.abs(h1p - h2p) > 180, (hsum + 360) / 2, hsum / 2)
    hpm = np.where(C1p * C2p == 0, hsum, hpm)
    T = 1 - 0.17 * np.cos(np.radians(hpm - 30)) + 0.24 * np.cos(np.radians(2 * hpm)) + 0.32 * np.cos(np.radians(3 * hpm + 6)) - 0.20 * np.cos(np.radians(4 * hpm - 63))
    dth = 30 * np.exp(-(((hpm - 275) / 25) ** 2))
    Rc = 2 * np.sqrt(Cpm ** 7 / (Cpm ** 7 + 25 ** 7))
    Sl = 1 + 0.015 * (Lpm - 50) ** 2 / np.sqrt(20 + (Lpm - 50) ** 2)
    Sc = 1 + 0.045 * Cpm; Sh = 1 + 0.015 * Cpm * T
    Rt = -np.sin(np.radians(2 * dth)) * Rc
    return np.sqrt((dLp / Sl) ** 2 + (dCp / Sc) ** 2 + (dHp / Sh) ** 2 + Rt * (dCp / Sc) * (dHp / Sh))


YY, XX = np.mgrid[0:1024, 0:1024].astype(np.float64) + 0.5


def sdf(rects):
    """圓角矩形的有號距離（px，負＝在裡面）；多個取最小"""
    out = None
    for (x, y, w, h, r) in rects:
        cx, cy = x + w / 2, y + h / 2
        qx = np.abs(XX - cx) - (w / 2 - r)
        qy = np.abs(YY - cy) - (h / 2 - r)
        d = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r
        out = d if out is None else np.minimum(out, d)
    return out


def box_blur(L, r):
    k = 2 * r + 1
    p = np.pad(L, r, mode="edge")
    c = np.cumsum(np.cumsum(p, 0), 1)
    c = np.pad(c, ((1, 0), (1, 0)))
    return (c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]) / (k * k)


def profile(L, shape, axis):
    x, y, w, h, r = shape
    span = np.arange(-16, min(41, int(min(w, h) / 2)))
    if axis == "h":   # 左緣橫切：y＝中心 ±2 平均
        cy = int(y + h / 2)
        rows = L[cy - 2: cy + 3, :]
        xs = np.clip((x + span).astype(int), 0, 1023)
        return span, rows[:, xs].mean(0)
    cx = int(x + w / 2)
    cols = L[:, cx - 2: cx + 3]
    ys = np.clip((y + span).astype(int), 0, 1023)
    return span, cols[ys, :].mean(1)


def best_shift(span, a, b):
    # a 真值、b 我們：找平移 s（b(x−s) 最貼 a）；只用 span ≥ −8 的部分
    best = (0.0, 1e9)
    for s in np.arange(-6, 6.01, 0.25):
        bs = np.interp(span - s, span, b)
        sel = (span >= -8) & (span - s >= span[0]) & (span - s <= span[-1])
        e = np.sqrt(np.mean((a[sel] - bs[sel]) ** 2))
        if e < best[1]:
            best = (float(s), float(e))
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--label", default="now")
    ap.add_argument("--no-plots", action="store_true")
    a = ap.parse_args()
    D = a.dir
    shapes = json.load(open(os.path.join(D, "shapes.json")))
    cases = []
    singles = [s for s in shapes if not s["group"]]
    groups = {}
    for s in shapes:
        if s["group"]:
            groups.setdefault(s["group"], []).append(s)
    entries = [(s["name"], [(*s["rect"], s["radius"])]) for s in singles] + [(g, [(*s["rect"], s["radius"]) for s in ss]) for g, ss in groups.items()]
    SDF = {name: sdf(rects) for name, rects in entries}
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception:
        plt = None
    for look in LOOKS:
        for bg in BGS:
            tag = f"{look}-{bg}"
            pt, po = os.path.join(D, f"truth-{tag}.png"), os.path.join(D, f"ours-{tag}.png")
            if not (os.path.exists(pt) and os.path.exists(po)):
                continue
            T, O, B = load(pt), load(po), load(os.path.join(D, f"bg-{bg}.png"))
            LT, LO, LB = srgb_to_lab(T), srgb_to_lab(O), srgb_to_lab(B)
            dE = de2000(LT, LO)
            if plt and not a.no_plots:
                fig, axs = plt.subplots(1, 3, figsize=(18, 6.4))
                axs[0].imshow(T); axs[0].set_title("truth " + tag); axs[1].imshow(O); axs[1].set_title("ours")
                im = axs[2].imshow(dE, vmin=0, vmax=10, cmap="magma"); axs[2].set_title("ΔE2000 (0–10)"); fig.colorbar(im, ax=axs[2], fraction=0.046)
                for x in axs:
                    x.axis("off")
                fig.tight_layout(); fig.savefig(os.path.join(D, f"dE-{a.label}-{tag}.png"), dpi=60); plt.close(fig)
                fig2, axs2 = plt.subplots(2, len(entries), figsize=(3.2 * len(entries), 6))
            hT = LT[..., 0] - box_blur(LT[..., 0], 5); hO = LO[..., 0] - box_blur(LO[..., 0], 5)
            for i, (name, rects) in enumerate(entries):
                d = SDF[name]
                m = d < 0
                inside = d < -2
                band = inside & (d >= -24)
                core = d < -24
                ring = (d > 2) & (d < 30)
                if name == "pair":   # 融合的橋：兩顆圓中間的方框也算（真值有橋就會在那裡）
                    x0 = rects[0][0] + rects[0][2]; x1 = rects[1][0]
                    bridge = np.zeros_like(m); bridge[int(rects[0][1] + 20): int(rects[0][1] + rects[0][3] - 20), int(x0 - 4): int(x1 + 4)] = True
                    ring = ring & ~bridge
                c = {"tag": tag, "look": look, "bg": bg, "shape": name}
                c["dE_in"] = float(dE[inside].mean()); c["dE_p95"] = float(np.percentile(dE[inside], 95))
                c["dE_band"] = float(dE[band].mean()) if band.any() else None
                c["dE_core"] = float(dE[core].mean()) if core.any() else None
                if name == "pair":
                    c["dE_bridge"] = float(dE[bridge].mean())
                c["shadowT"] = float((LT[..., 0] - LB[..., 0])[ring].mean()); c["shadowO"] = float((LO[..., 0] - LB[..., 0])[ring].mean())
                if core.any():
                    c["detailT"] = float(hT[core].std()); c["detailO"] = float(hO[core].std())
                c["chromaT"] = float(np.hypot(LT[..., 1], LT[..., 2])[inside].mean()); c["chromaO"] = float(np.hypot(LO[..., 1], LO[..., 2])[inside].mean())
                c["LT"] = float(LT[..., 0][inside].mean()); c["LO"] = float(LO[..., 0][inside].mean())
                r0 = rects[0]
                for axis in ("h", "v"):
                    span, pT = profile(LT[..., 0], r0, axis)
                    _, pO = profile(LO[..., 0], r0, axis)
                    _, pB = profile(LB[..., 0], r0, axis)
                    s, e = best_shift(span, pT, pO)
                    near = (span >= -3) & (span <= 6)
                    dT = (pT - pB)[near]; dO = (pO - pB)[near]
                    c[f"shift_{axis}"] = s; c[f"rms_{axis}"] = e
                    c[f"rimT_{axis}"] = float(dT[np.argmax(np.abs(dT))]); c[f"rimO_{axis}"] = float(dO[np.argmax(np.abs(dO))])
                    if plt and not a.no_plots:
                        ax = axs2[0 if axis == "h" else 1][i]
                        ax.plot(span, pB, color="0.7", lw=1, label="bg"); ax.plot(span, pT, "k-", lw=1.4, label="truth"); ax.plot(span, pO, "r--", lw=1.2, label="ours")
                        ax.axvline(0, color="0.5", lw=0.5); ax.set_title(f"{name} {'left' if axis == 'h' else 'top'}", fontsize=8)
                cases.append(c)
            if plt and not a.no_plots:
                axs2[0][0].legend(fontsize=6)
                fig2.tight_layout(); fig2.savefig(os.path.join(D, f"prof-{a.label}-{tag}.png"), dpi=70); plt.close(fig2)
    json.dump(cases, open(os.path.join(D, f"report-{a.label}.json"), "w"), indent=1)
    f = lambda v: "–" if v is None else (f"{v:.2f}" if abs(v) < 100 else f"{v:.0f}")
    lines = ["| case | shape | ΔE in | p95 | band | core | shift h/v | rms h/v | rim T/O (h) | shadow T/O | detail T/O | L T/O | C T/O |", "|" + "---|" * 13]
    for c in cases:
        lines.append(f"| {c['tag']} | {c['shape']} | {f(c['dE_in'])} | {f(c['dE_p95'])} | {f(c['dE_band'])} | {f(c['dE_core'])} | {f(c['shift_h'])}/{f(c['shift_v'])} | "
                     f"{f(c['rms_h'])}/{f(c['rms_v'])} | {f(c['rimT_h'])}/{f(c['rimO_h'])} | {f(c['shadowT'])}/{f(c['shadowO'])} | {f(c.get('detailT'))}/{f(c.get('detailO'))} | "
                     f"{f(c['LT'])}/{f(c['LO'])} | {f(c['chromaT'])}/{f(c['chromaO'])} |")
    # 摘要：每個外觀、每個形狀
    lines.append("")
    lines.append("| look | shape | mean ΔE in (5 bgs) | max |shift| | ")
    lines.append("|---|---|---|---|")
    for look in LOOKS:
        for (name, _) in entries:
            cc = [c for c in cases if c["look"] == look and c["shape"] == name]
            if cc:
                lines.append(f"| {look} | {name} | {np.mean([c['dE_in'] for c in cc]):.2f} | {max(max(abs(c['shift_h']), abs(c['shift_v'])) for c in cc):.2f} |")
    allde = [c["dE_in"] for c in cases]
    lines.append(f"\nALL: mean ΔE in {np.mean(allde):.2f}, cases ≤ 2: {sum(1 for v in allde if v <= 2)}/{len(allde)}, "
                 f"|shift| ≤ 1: {sum(1 for c in cases if abs(c['shift_h']) <= 1 and abs(c['shift_v']) <= 1)}/{len(cases)}")
    open(os.path.join(D, f"report-{a.label}.md"), "w").write("\n".join(lines) + "\n")
    print("\n".join(lines[-(len(LOOKS) * len(entries) + 4):]))


if __name__ == "__main__":
    main()
