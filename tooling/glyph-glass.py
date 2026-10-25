#!/usr/bin/env python3
"""glyph-glass：錶面玻璃字形（大時間、溫度、Flow 的水珠、家庭模塊的磚）跟官方錶面圖比「玻璃本身」。

背景不同（官方的照片／桌布跟我們的示範資料不一樣），所以不直接比顏色，比玻璃對背景做了什麼：
  fill   字形核心的顏色（Lab 中位數）；bg 字外 12–28 px 一圈的顏色
  T      轉移＝fill − bg（Lab）。fill ΔE＝ΔE2000(我們的 bg + 官方的 T, 我們的 fill)；目標 ≤ 5
  profile 邊緣剖面形狀：我們的對官方的（各自減 fill），平移 ±3 px 取最貼的 RMSE（L*）與平移量
  rim    沿有號距離（字裡為正、每 1 px 一格）的 L* 剖面：亮邊峰值高出 fill 多少（peak）、峰在哪（pos，px）、
         高出 fill 一半以上的寬度（width，px）、緣內 4–12 px 的暗帶（inner，L* 低於 fill 多少）

用法
  uv run --with numpy --with scipy --with pillow python tooling/glyph-glass.py OURS.png MASK.png REF.png [REF2.png …]
       [--flip] [--json OUT.json]
  MASK 是我們字形的遮罩（白＝字，1024²；HOMEPLAY_LG_MASK 寫出來的；--flip 上下翻）。
  官方圖上的字形位置用遮罩的邊去對官方圖的邊（平移＋縮放，找邊上梯度最大的那組），再量。多張官方圖取平均。
"""
import argparse
import json
import sys

import numpy as np
from PIL import Image, ImageOps
from scipy import ndimage


def load(p):
    return np.asarray(Image.open(p).convert("RGB").resize((1024, 1024), Image.LANCZOS), dtype=np.float64) / 255.0


def srgb_to_lab(rgb):
    c = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    m = np.array([[0.4124564, 0.3575761, 0.1804375], [0.2126729, 0.7151522, 0.0721750], [0.0193339, 0.1191920, 0.9503041]])
    xyz = c @ m.T / np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > (6 / 29) ** 3, np.cbrt(xyz), xyz / (3 * (6 / 29) ** 2) + 4 / 29)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


def de2000(lab1, lab2):
    L1, a1, b1 = lab1[..., 0], lab1[..., 1], lab1[..., 2]
    L2, a2, b2 = lab2[..., 0], lab2[..., 1], lab2[..., 2]
    C1 = np.hypot(a1, b1); C2 = np.hypot(a2, b2); Cm = (C1 + C2) / 2
    G = 0.5 * (1 - np.sqrt(Cm ** 7 / (Cm ** 7 + 25 ** 7)))
    a1p = (1 + G) * a1; a2p = (1 + G) * a2
    C1p = np.hypot(a1p, b1); C2p = np.hypot(a2p, b2)
    h1p = np.degrees(np.arctan2(b1, a1p)) % 360; h2p = np.degrees(np.arctan2(b2, a2p)) % 360
    dLp = L2 - L1; dCp = C2p - C1p; dhp = h2p - h1p
    dhp = np.where(dhp > 180, dhp - 360, dhp); dhp = np.where(dhp < -180, dhp + 360, dhp)
    dhp = np.where(C1p * C2p == 0, 0, dhp)
    dHp = 2 * np.sqrt(C1p * C2p) * np.sin(np.radians(dhp) / 2)
    Lpm = (L1 + L2) / 2; Cpm = (C1p + C2p) / 2; hsum = h1p + h2p
    hpm = np.where(np.abs(h1p - h2p) > 180, (hsum + 360) / 2, hsum / 2); hpm = np.where(C1p * C2p == 0, hsum, hpm)
    T = 1 - 0.17 * np.cos(np.radians(hpm - 30)) + 0.24 * np.cos(np.radians(2 * hpm)) + 0.32 * np.cos(np.radians(3 * hpm + 6)) - 0.20 * np.cos(np.radians(4 * hpm - 63))
    dth = 30 * np.exp(-(((hpm - 275) / 25) ** 2)); Rc = 2 * np.sqrt(Cpm ** 7 / (Cpm ** 7 + 25 ** 7))
    Sl = 1 + 0.015 * (Lpm - 50) ** 2 / np.sqrt(20 + (Lpm - 50) ** 2); Sc = 1 + 0.045 * Cpm; Sh = 1 + 0.015 * Cpm * T
    Rt = -np.sin(np.radians(2 * dth)) * Rc
    return float(np.sqrt((dLp / Sl) ** 2 + (dCp / Sc) ** 2 + (dHp / Sh) ** 2 + Rt * (dCp / Sc) * (dHp / Sh)))


def warp(mask, t):
    s, tx, ty = t
    cy, cx = np.mean(np.nonzero(mask), axis=1)
    Yg, Xg = np.mgrid[0:1024, 0:1024].astype(np.float64)
    return ndimage.map_coordinates(mask.astype(np.float64), [(Yg - cy - ty) / s + cy, (Xg - cx - tx) / s + cx], order=0) > 0.5


def register(mask, lab, rng=96, clip=None, refclip=None, scales=(0.85, 1.15)):
    """平移＋縮放（繞遮罩重心），讓遮罩的邊落在官方圖梯度最大的地方"""
    L = ndimage.gaussian_filter(lab[..., 0], 1.0)
    grad = np.hypot(ndimage.sobel(L, 0), ndimage.sobel(L, 1))
    grad[:24] = 0; grad[-24:] = 0; grad[:, :24] = 0; grad[:, -24:] = 0   # 螢幕邊與圓角不算
    edge = mask & ~ndimage.binary_erosion(mask)
    if clip is not None: edge &= clip
    ys, xs = np.nonzero(edge)
    if len(xs) > 4000:
        pick = np.random.default_rng(1).choice(len(xs), 4000, replace=False); ys, xs = ys[pick], xs[pick]
    cy, cx = np.mean(np.nonzero(mask), axis=1)

    def score(s, tx, ty):
        X = (xs - cx) * s + cx + tx; Y = (ys - cy) * s + cy + ty
        ok = (X >= 0) & (X < 1023) & (Y >= 0) & (Y < 1023)
        if ok.mean() < 0.8: return -1
        if refclip is not None:
            x0, y0, w0, h0 = refclip; ok &= (X >= x0) & (X < x0 + w0) & (Y >= y0) & (Y < y0 + h0)
            if ok.sum() < 200: return -1
        return float(ndimage.map_coordinates(grad, [Y[ok], X[ok]], order=1).mean())

    best = (-1, 1, 0, 0)
    for s in np.arange(scales[0], scales[1] + 0.001, 0.025):
        for tx in range(-rng, rng + 1, 6):
            for ty in range(-rng, rng + 1, 6):
                v = score(s, tx, ty)
                if v > best[0]: best = (v, s, tx, ty)
    _, s0, x0, y0 = best
    for s in np.arange(s0 - 0.02, s0 + 0.021, 0.005):
        for tx in range(x0 - 6, x0 + 7):
            for ty in range(y0 - 6, y0 + 7):
                v = score(s, tx, ty)
                if v > best[0]: best = (v, s, tx, ty)
    _, s, tx, ty = best
    t = (round(float(s), 3), int(tx), int(ty))
    return warp(mask, t), t


def measure(lab, mask, clip=None):
    din = ndimage.distance_transform_edt(mask); dout = ndimage.distance_transform_edt(~mask)
    sd = np.where(mask, din - 0.5, -(dout - 0.5))
    core = din >= max(4.0, 0.45 * din.max())
    ring = (dout >= 12) & (dout <= 28)
    # clip 只限玻璃核心（避開磚上的文字內容）；背景環帶在玻璃外，永遠用整張
    if clip is not None: core &= clip; sd = np.where(clip, sd, 999)
    fill = np.median(lab[core], axis=0); bg = np.median(lab[ring], axis=0)
    prof = {}
    for d in range(-8, 25):
        sel = (sd >= d - 0.5) & (sd < d + 0.5)
        if sel.sum() > 20: prof[d] = float(lab[..., 0][sel].mean())
    peak, pos, width, inner = profile_stats(prof, fill[0])
    return {"fill": fill.tolist(), "bg": bg.tolist(), "T": (fill - bg).tolist(), "peak": peak, "pos": pos, "width": width,
            "inner": inner, "profile": prof, "core_px": int(core.sum())}


def profile_stats(prof, fillL):
    near = {d: v for d, v in prof.items() if -2 <= d <= 6}
    pos = max(near, key=near.get) if near else 0
    peak = near.get(pos, fillL) - fillL
    half = fillL + peak / 2
    width = sum(1 for d, v in prof.items() if -3 <= d <= 16 and v >= half) if peak > 2 else 0
    inner = [prof[d] for d in range(4, 13) if d in prof]
    return float(peak), int(pos), int(width), float(fillL - min(inner)) if inner else 0.0


def measure_probes(lab, pr):
    """手量：inside／outside 方框（Lab 中位數）、橫掃描線 [y, 從字外的 x, 到字裡的 x]：邊＝L* 梯度最大處"""
    pick = lambda rs: np.concatenate([lab[y:y + h, x:x + w].reshape(-1, 3) for x, y, w, h in rs])
    fill = np.median(pick(pr["inside"]), axis=0); bg = np.median(pick(pr["outside"]), axis=0)
    L = ndimage.gaussian_filter(lab[..., 0], 0.7)
    acc = {}
    for y, x0, x1 in pr["scans"]:
        step = 1 if x1 > x0 else -1
        xs = np.arange(x0, x1, step); line = L[y, xs]
        e = int(np.argmax(np.abs(np.diff(line)))) + 1
        for i, v in enumerate(line):
            acc.setdefault(i - e, []).append(float(v))
    prof = {d: float(np.mean(v)) for d, v in acc.items() if -8 <= d <= 24}
    peak, pos, width, inner = profile_stats(prof, fill[0])
    return {"fill": fill.tolist(), "bg": bg.tolist(), "T": (fill - bg).tolist(), "peak": peak, "pos": pos, "width": width, "inner": inner, "profile": prof}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ours"); ap.add_argument("mask"); ap.add_argument("refs", nargs="+")
    ap.add_argument("--flip", action="store_true"); ap.add_argument("--json")
    ap.add_argument("--overlay", help="把對好的字形邊畫在官方圖上（檢查對位）")
    ap.add_argument("--range", type=int, default=96, help="平移搜尋範圍（px）")
    ap.add_argument("--clip", help="只量這一塊 x,y,w,h（兩邊都裁）")
    ap.add_argument("--ref-clip", help="官方圖上只用這一塊對位與量 x,y,w,h（字被人擋住時）")
    ap.add_argument("--scales", default="0.85,1.15", help="縮放搜尋範圍 lo,hi")
    ap.add_argument("--reg-cache", help="對位結果存這裡；有了就直接用（同一個遮罩反覆量時）")
    ap.add_argument("--probes", help="JSON：{官方圖檔名: {inside: [[x,y,w,h]], outside: [...], scans: [[y, x外, x裡]]}}——版面跟我們差太多、對不上位時手量")
    ap.add_argument("--component", type=int, help="只用遮罩的第 K 塊（由左到右，0 起；版面不同時一個字一個字對）")
    a = ap.parse_args()
    m = Image.open(a.mask).convert("L").resize((1024, 1024))
    if a.flip: m = ImageOps.flip(m)
    mask = np.asarray(m) > 127
    if a.component is not None:
        lb, n = ndimage.label(mask)
        objs = sorted(range(1, n + 1), key=lambda i: ndimage.find_objects(lb)[i - 1][1].start)
        mask = lb == objs[a.component]
    clip = None
    if a.clip:
        x, y, w, h = map(int, a.clip.split(",")); clip = np.zeros((1024, 1024), bool); clip[y:y + h, x:x + w] = True
    ours = measure(srgb_to_lab(load(a.ours)), mask, clip)
    refs = []
    probes = json.load(open(a.probes)) if a.probes else {}
    for r in a.refs:
        lab = srgb_to_lab(load(r))
        name = r.split("/")[-1]
        if name in probes:
            mr = measure_probes(lab, probes[name]); mr["ref"] = r; mr["transform"] = "probes"; refs.append(mr); continue
        rc = tuple(map(int, a.ref_clip.split(","))) if a.ref_clip else None
        cache = json.load(open(a.reg_cache)) if a.reg_cache and __import__("os").path.exists(a.reg_cache) else {}
        if name in cache:
            tr = tuple(cache[name]); rm = warp(mask, tr)
        else:
            rm, tr = register(mask, lab, a.range, clip, rc, tuple(map(float, a.scales.split(","))))
            if a.reg_cache: cache[name] = tr; json.dump(cache, open(a.reg_cache, "w"))
        rclip = clip
        if rc:
            rclip = np.zeros((1024, 1024), bool); rclip[rc[1]:rc[1] + rc[3], rc[0]:rc[0] + rc[2]] = True
        if a.overlay:
            im = Image.open(r).convert("RGB").resize((1024, 1024)); px = np.asarray(im).copy()
            px[rm & ~ndimage.binary_erosion(rm, iterations=2)] = [255, 0, 0]
            Image.fromarray(px).save(a.overlay.replace(".png", "-%d.png" % len(refs)))
        mr = measure(lab, rm, rclip); mr["ref"] = r; mr["transform"] = tr
        refs.append(mr)
    T = np.mean([r["T"] for r in refs], axis=0)
    # 邊緣剖面的形狀（相對各自的 fill）：官方的平均剖面跟我們的，平移 −3…+3 px 取最貼的，RMSE（L*）
    def rel(m): return {int(k): v - m["fill"][0] for k, v in m["profile"].items()}
    ro = rel(ours); rr = {}
    for r in refs:
        for k, v in rel(r).items(): rr.setdefault(k, []).append(v)
    rr = {k: float(np.mean(v)) for k, v in rr.items()}
    fit = []
    for sh in range(-3, 4):
        ds = [d for d in range(-6, 17) if d in ro and d + sh in rr]
        fit.append((float(np.sqrt(np.mean([(ro[d] - rr[d + sh]) ** 2 for d in ds]))), sh))
    prof_rmse, prof_shift = min(fit)
    pred = np.array(ours["bg"]) + T
    out = {
        "fill_dE": de2000(pred, np.array(ours["fill"])),
        "profile_rmse": prof_rmse, "profile_shift": prof_shift,
        "rim_peak": [ours["peak"], float(np.mean([r["peak"] for r in refs]))],
        "rim_pos": [ours["pos"], float(np.mean([r["pos"] for r in refs]))],
        "rim_width": [ours["width"], float(np.mean([r["width"] for r in refs]))],
        "inner": [ours["inner"], float(np.mean([r["inner"] for r in refs]))],
        "T": [ours["T"], T.tolist()], "ours": ours, "refs": refs,
    }
    print("profile RMSE %.2f L* (shift %+d px)" % (prof_rmse, prof_shift))
    print("fill ΔE00 (transfer) %.2f | rim peak ΔL* ours %.1f ref %.1f | pos %d vs %.1f | width %d vs %.1f px | inner dark %.1f vs %.1f" % (
        out["fill_dE"], *out["rim_peak"], *out["rim_pos"], *out["rim_width"], *out["inner"]))
    print("  T (fill−bg Lab) ours %s ref %s | ref transforms %s" % (np.round(ours["T"], 1).tolist(), np.round(T, 1).tolist(), [r["transform"] for r in refs]))
    if a.json:
        json.dump(out, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    sys.exit(main())
