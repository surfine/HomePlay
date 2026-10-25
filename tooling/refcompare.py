#!/usr/bin/env python3
"""refcompare：把我們的 --screen-png 跟一張參考圖逐元件對照（只在本機用；只需要 Pillow）。

用法
  python3 tooling/refcompare.py OURS.png REF.png -o OUT.png [--mask mask.json] [--boxes boxes.json]
                                [--bg auto|#rrggbb] [--thresh 20] [--merge 14] [--min-area 120] [--no-auto]

  OURS.png   我們的畫面：.build/release/homeplay-pet … --demo-official --lang en --screen-png OURS.png
  REF.png    參考圖（1024²；不是 1024² 會縮放）。參考圖只從命令列給，這支程式不內建、不複製任何參考圖。
  -o OUT.png 輸出一張對照表：上排 我們｜參考（框上編號）、50% 疊合、邊緣差異（紅＝只有我們、青＝只有參考、白＝重疊）；
             下面是誤差表。同名的 OUT.txt（表）與 OUT.json（數字）也會寫出來，表也印到 stdout。

  --mask     不比對的區域（照片、影片等內容）：{"ignore": [[x,y,w,h], …], "ignore_ours": […], "ignore_ref": […]}
  --boxes    手動框：[{"name": "標題", "region": [x,y,w,h]}]（兩張圖各自在 region 裡找前景外框）
             或 [{"name": "鈕", "ours": [x,y,w,h], "ref": [x,y,w,h]}]（直接給兩邊的框）
  --bg       背景色（預設 auto：螢幕內最常見的顏色）；前景＝跟背景的差（RGB 最大通道）超過 --thresh
  --merge    自動找框時，相距小於這個 px 的前景併成一塊（字併成一行）
  --corner   螢幕圓角半徑（預設 138；圓角外的像素不算）。0＝不裁
  --no-auto  只用手動框

誤差表：每一列是一對框（自動配對：中心距離＋大小差最小者），Δx／Δy／Δw／Δh 是「我們 − 參考」的像素，
  Δx%／Δy% 以 1024 畫布為分母、Δw%／Δh% 以參考框的寬高為分母；ΔE 是 CIE76，比的是框內「平坦區」（邊緣弱的像素）
  的主色（例如膠囊的底色、方塊的填色；純文字框會是背景色），不在平坦區的像素不算；dEink 比的是框內前景（字、符號、
  刻度的實心部分）的主色。手動框可以兩邊給不同的搜尋區：{"name": …, "region_ours": […], "region_ref": […]}。
  ok 欄：位置差 ≤ 30 px（3%）且 ΔE ≤ 5（realism-spec3 的目標）。沒配到的框列在最後。
"""
import argparse
import json
import math
import os
import sys
from collections import Counter, deque

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

SIDE = 1024
CELL = 4  # 連通塊在 1/4 解析度上算（256² 格），再回到原圖量精確外框


# MARK: 色彩

def srgb_to_lab(rgb):
    def lin(c):
        c /= 255.0
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(float(v)) for v in rgb[:3])
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    y = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 1.0
    z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883

    def f(t):
        return t ** (1 / 3) if t > 216 / 24389 else (24389 / 27 * t + 16) / 116
    fx, fy, fz = f(x), f(y), f(z)
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))


def delta_e(a, b):
    la, lb = srgb_to_lab(a), srgb_to_lab(b)
    return math.sqrt(sum((p - q) ** 2 for p, q in zip(la, lb)))


def hexc(c):
    return "#%02X%02X%02X" % tuple(int(v) for v in c[:3])


def parse_hex(s):
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


# MARK: 圖

def load(path):
    im = Image.open(path).convert("RGBA")
    if im.size != (SIDE, SIDE):
        im = im.resize((SIDE, SIDE), Image.LANCZOS)
    # 透明的地方當黑（螢幕外）
    bg = Image.new("RGBA", im.size, (0, 0, 0, 255))
    return Image.alpha_composite(bg, im).convert("RGB")


def screen_mask(radius):
    """螢幕圓角以內＝255（圓弧近似連續曲率）"""
    m = Image.new("L", (SIDE, SIDE), 0)
    if radius <= 0:
        m.paste(255, (0, 0, SIDE, SIDE))
        return m
    # 圓弧比連續曲率的角「胖」：多內縮 8 px、半徑放大 1.15 倍，角落外緣的黑邊與抗鋸齒不會變成假前景
    ImageDraw.Draw(m).rounded_rectangle((8, 8, SIDE - 9, SIDE - 9), radius=radius * 1.15, fill=255)
    return m


def ignore_mask(rects):
    m = Image.new("L", (SIDE, SIDE), 0)
    d = ImageDraw.Draw(m)
    for x, y, w, h in rects:
        d.rectangle((x, y, x + w - 1, y + h - 1), fill=255)
    return m


def dominant(img, mask, q=8):
    """mask 範圍內最常見的顏色（每通道量化到 q 階後的眾數，回傳該格的平均色）"""
    small = img.resize((256, 256), Image.BILINEAR)
    ms = mask.resize((256, 256), Image.NEAREST)
    px, mp = small.load(), ms.load()
    buckets = Counter()
    sums = {}
    for y in range(256):
        for x in range(256):
            if mp[x, y] < 128:
                continue
            c = px[x, y]
            k = (c[0] * q // 256, c[1] * q // 256, c[2] * q // 256)
            buckets[k] += 1
            s = sums.setdefault(k, [0, 0, 0])
            s[0] += c[0]; s[1] += c[1]; s[2] += c[2]
    if not buckets:
        return (0, 0, 0)
    k, n = buckets.most_common(1)[0]
    s = sums[k]
    return (s[0] / n, s[1] / n, s[2] / n)


def foreground(img, valid, bg, thresh):
    """跟背景的差（RGB 最大通道）> thresh，而且在 valid 裡"""
    solid = Image.new("RGB", img.size, tuple(int(v) for v in bg))
    diff = ImageChops.difference(img, solid)
    r, g, b = diff.split()
    mx = ImageChops.lighter(ImageChops.lighter(r, g), b)
    fg = mx.point(lambda v: 255 if v > thresh else 0)
    return ImageChops.multiply(fg, valid)


def components(fg, merge, min_area):
    """前景 → 連通塊外框（原圖座標）。先縮成 CELL 格、膨脹 merge，再 4 連通 BFS，最後回原圖量精確外框"""
    n = SIDE // CELL
    small = fg.resize((n, n), Image.BOX).point(lambda v: 255 if v > 0 else 0)
    k = int(round(merge / (2 * CELL)))   # 每邊膨脹 merge/2：相距 < merge 的兩塊才接起來
    if k > 0:
        small = small.filter(ImageFilter.MaxFilter(2 * k + 1))
    px = small.load()
    seen = bytearray(n * n)
    boxes = []
    for y0 in range(n):
        for x0 in range(n):
            if px[x0, y0] == 0 or seen[y0 * n + x0]:
                continue
            q = deque([(x0, y0)])
            seen[y0 * n + x0] = 1
            x1 = x2 = x0
            y1 = y2 = y0
            while q:
                x, y = q.popleft()
                x1, x2, y1, y2 = min(x1, x), max(x2, x), min(y1, y), max(y2, y)
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    a, b = x + dx, y + dy
                    if 0 <= a < n and 0 <= b < n and px[a, b] and not seen[b * n + a]:
                        seen[b * n + a] = 1
                        q.append((a, b))
            region = (x1 * CELL, y1 * CELL, (x2 + 1) * CELL, (y2 + 1) * CELL)
            bb = fg.crop(region).getbbox()
            if not bb:
                continue
            box = (region[0] + bb[0], region[1] + bb[1], bb[2] - bb[0], bb[3] - bb[1])
            if box[2] * box[3] >= min_area:
                boxes.append(box)
    return boxes


def box_in_region(fg, region):
    x, y, w, h = region
    bb = fg.crop((x, y, x + w, y + h)).getbbox()
    return None if not bb else (x + bb[0], y + bb[1], bb[2] - bb[0], bb[3] - bb[1])


def flat_color(img, edges, box, valid, fg=None):
    """框內平坦區（邊緣弱）的主色；給了 fg 就只看前景（字、符號的實心部分＝墨色）"""
    x, y, w, h = box
    if w < 2 or h < 2:
        return None
    crop = img.crop((x, y, x + w, y + h))
    e = edges.crop((x, y, x + w, y + h)).point(lambda v: 255 if v < 24 else 0)
    m = ImageChops.multiply(e, valid.crop((x, y, x + w, y + h)))
    if fg is not None:
        m = ImageChops.multiply(m, fg.crop((x, y, x + w, y + h)))
    if not m.getbbox():
        return None
    # dominant() 在 256² 上取樣：小框直接放大到 256 再取
    return dominant(crop.resize((256, 256), Image.NEAREST), m.resize((256, 256), Image.NEAREST))


def edge_map(img):
    return img.convert("L").filter(ImageFilter.FIND_EDGES)


# MARK: 配對

def match(ours, refs):
    """貪婪配對：參考框照面積由大到小，各挑一個成本最低的我們的框（中心距離＋寬高差；距離 > 160 或寬高比差 2.5 倍以上不配）"""
    pairs, used = [], set()
    for j in sorted(range(len(refs)), key=lambda j: -refs[j][2] * refs[j][3]):
        r = refs[j]
        rc = (r[0] + r[2] / 2, r[1] + r[3] / 2)
        best, cost = None, 1e18
        for i, o in enumerate(ours):
            if i in used:
                continue
            oc = (o[0] + o[2] / 2, o[1] + o[3] / 2)
            d = math.hypot(oc[0] - rc[0], oc[1] - rc[1])
            # 距離太遠、或大小差兩倍半以上（刻度配到按鈕那種）都不配
            if d > min(160, 40 + max(r[2], r[3], o[2], o[3])):
                continue
            if not (0.4 <= o[2] / max(1, r[2]) <= 2.5 and 0.4 <= o[3] / max(1, r[3]) <= 2.5):
                continue
            c = d + 0.5 * (abs(o[2] - r[2]) + abs(o[3] - r[3]))
            if c < cost:
                best, cost = i, c
        if best is not None:
            used.add(best)
            pairs.append((best, j))
    pairs.sort(key=lambda p: (refs[p[1]][1], refs[p[1]][0]))
    return pairs, [i for i in range(len(ours)) if i not in used], [j for j in range(len(refs)) if j not in {p[1] for p in pairs}]


# MARK: 輸出

PALETTE = [(255, 59, 48), (0, 136, 255), (52, 199, 89), (255, 149, 0), (175, 82, 222), (0, 195, 208), (255, 45, 85), (172, 127, 94),
           (88, 86, 214), (255, 204, 0)]


def font(size):
    for p in ("/System/Library/Fonts/SFNSMono.ttf", "/System/Library/Fonts/Menlo.ttc", "/System/Library/Fonts/Monaco.ttf"):
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except OSError:
                pass
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()


def draw_boxes(img, boxes, labels, colors):
    out = img.copy()
    d = ImageDraw.Draw(out)
    f = font(22)
    for b, lab, c in zip(boxes, labels, colors):
        x, y, w, h = b
        d.rectangle((x, y, x + w - 1, y + h - 1), outline=c, width=3)
        tw = d.textlength(lab, font=f)
        d.rectangle((x, max(0, y - 26), x + tw + 8, max(0, y - 26) + 26), fill=c)
        d.text((x + 4, max(0, y - 26) + 1), lab, fill=(255, 255, 255), font=f)
    return out


def edge_diff(a, b, valid):
    ea = edge_map(a).point(lambda v: 255 if v > 40 else 0)
    eb = edge_map(b).point(lambda v: 255 if v > 40 else 0)
    ea, eb = ImageChops.multiply(ea, valid), ImageChops.multiply(eb, valid)
    # 紅＝只有我們、青＝只有參考、白＝兩邊都有
    return Image.merge("RGB", (ea, eb, eb))


def main():
    ap = argparse.ArgumentParser(description="our --screen-png vs a reference screen: side-by-side, overlay, edge diff, box error table")
    ap.add_argument("ours")
    ap.add_argument("ref")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--mask")
    ap.add_argument("--boxes")
    ap.add_argument("--bg", default="auto")
    ap.add_argument("--thresh", type=int, default=20)
    ap.add_argument("--merge", type=int, default=14)
    ap.add_argument("--min-area", type=int, default=120)
    ap.add_argument("--corner", type=float, default=138)
    ap.add_argument("--no-auto", action="store_true")
    ap.add_argument("--title", default=None)
    a = ap.parse_args()

    ours, ref = load(a.ours), load(a.ref)
    scr = screen_mask(int(a.corner))
    mask = json.load(open(a.mask)) if a.mask else {}
    ig_all = mask.get("ignore", [])
    valid_o = ImageChops.multiply(scr, ImageChops.invert(ignore_mask(ig_all + mask.get("ignore_ours", []))))
    valid_r = ImageChops.multiply(scr, ImageChops.invert(ignore_mask(ig_all + mask.get("ignore_ref", []))))
    valid_both = ImageChops.multiply(valid_o, valid_r)

    bg_o = dominant(ours, valid_o) if a.bg == "auto" else parse_hex(a.bg)
    bg_r = dominant(ref, valid_r) if a.bg == "auto" else parse_hex(a.bg)
    fg_o = foreground(ours, valid_o, bg_o, a.thresh)
    fg_r = foreground(ref, valid_r, bg_r, a.thresh)
    ed_o, ed_r = edge_map(ours), edge_map(ref)

    rows = []  # (name, ourbox, refbox)
    manual = json.load(open(a.boxes)) if a.boxes else []
    for i, m in enumerate(manual):
        name = m.get("name", "m%d" % (i + 1))
        if "region" in m or "region_ours" in m:
            ro, rr = m.get("region_ours", m.get("region")), m.get("region_ref", m.get("region"))
            rows.append((name, box_in_region(fg_o, ro), box_in_region(fg_r, rr)))
        else:
            rows.append((name, tuple(m["ours"]) if m.get("ours") else None, tuple(m["ref"]) if m.get("ref") else None))
    un_o, un_r = [], []
    if not a.no_auto:
        bo = components(fg_o, a.merge, a.min_area)
        br = components(fg_r, a.merge, a.min_area)
        pairs, un_oi, un_ri = match(bo, br)
        for k, (i, j) in enumerate(pairs):
            rows.append(("a%d" % (k + 1), bo[i], br[j]))
        un_o = [bo[i] for i in un_oi]
        un_r = [br[j] for j in un_ri]

    # 量
    table, data = [], []
    hdr = "%-8s %-20s %-20s %6s %6s %6s %6s %6s %6s %6s %6s %6s  %-7s %-7s %6s  %-7s %-7s %s" % (
        "#", "ours x,y,w,h", "ref x,y,w,h", "dx", "dy", "dw", "dh", "dx%", "dy%", "dw%", "dh%", "dE", "ours", "ref", "dEink", "ours", "ref", "ok")
    table.append(hdr)
    table.append("-" * len(hdr))
    for name, o, r in rows:
        if not o or not r:
            table.append("%-8s %-20s %-20s  (one side missing)" % (name, o and "%d,%d,%d,%d" % o or "-", r and "%d,%d,%d,%d" % r or "-"))
            data.append({"name": name, "ours": o, "ref": r})
            continue
        dx, dy, dw, dh = o[0] - r[0], o[1] - r[1], o[2] - r[2], o[3] - r[3]
        co = flat_color(ours, ed_o, o, valid_o)
        cr = flat_color(ref, ed_r, r, valid_r)
        de = delta_e(co, cr) if co and cr else float("nan")
        io = flat_color(ours, ed_o, o, valid_o, fg_o)
        ir = flat_color(ref, ed_r, r, valid_r, fg_r)
        di = delta_e(io, ir) if io and ir else float("nan")
        ok = max(abs(dx), abs(dy)) <= 30 and (math.isnan(de) or de <= 5)
        table.append("%-8s %-20s %-20s %6d %6d %6d %6d %5.1f%% %5.1f%% %5.1f%% %5.1f%% %6.1f  %-7s %-7s %6.1f  %-7s %-7s %s" % (
            name, "%d,%d,%d,%d" % o, "%d,%d,%d,%d" % r, dx, dy, dw, dh, 100 * dx / SIDE, 100 * dy / SIDE,
            100 * dw / max(1, r[2]), 100 * dh / max(1, r[3]), de, hexc(co) if co else "-", hexc(cr) if cr else "-",
            di, hexc(io) if io else "-", hexc(ir) if ir else "-", "ok" if ok else "MISS"))
        data.append({"name": name, "ours": o, "ref": r, "dx": dx, "dy": dy, "dw": dw, "dh": dh,
                     "dE": None if math.isnan(de) else round(de, 2), "ours_color": co and hexc(co), "ref_color": cr and hexc(cr),
                     "dE_ink": None if math.isnan(di) else round(di, 2), "ours_ink": io and hexc(io), "ref_ink": ir and hexc(ir), "ok": ok})
    for b in un_o:
        table.append("%-8s %-20s %-20s  (only in ours)" % ("+", "%d,%d,%d,%d" % b, "-"))
    for b in un_r:
        table.append("%-8s %-20s %-20s  (only in ref)" % ("-", "-", "%d,%d,%d,%d" % b))
    bg_de = delta_e(bg_o, bg_r)
    matched = [d for d in data if "dx" in d]
    summary = "background ours %s ref %s dE %.1f | pairs %d, ok %d | only ours %d, only ref %d" % (
        hexc(bg_o), hexc(bg_r), bg_de, len(matched), sum(1 for d in matched if d["ok"]), len(un_o), len(un_r))
    if matched:
        mpos = sum(max(abs(d["dx"]), abs(d["dy"])) for d in matched) / len(matched)
        des = [d["dE"] for d in matched if d["dE"] is not None]
        summary += " | mean |pos| %.1f px" % mpos + (" | mean dE %.1f" % (sum(des) / len(des)) if des else "")
    table.insert(0, summary)

    # 圖
    labels, co_l, boxes_o, boxes_r, lab_r, co_r = [], [], [], [], [], []
    for k, (name, o, r) in enumerate(rows):
        c = PALETTE[k % len(PALETTE)]
        if o:
            boxes_o.append(o); labels.append(name); co_l.append(c)
        if r:
            boxes_r.append(r); lab_r.append(name); co_r.append(c)
    for b in un_o:
        boxes_o.append(b); labels.append("+"); co_l.append((128, 128, 128))
    for b in un_r:
        boxes_r.append(b); lab_r.append("-"); co_r.append((128, 128, 128))
    # 遮掉的區域畫斜線灰
    def hatch(img, valid):
        g = Image.new("RGB", img.size, (90, 90, 90))
        return Image.composite(img, Image.blend(img, g, 0.6), valid)
    p1 = draw_boxes(hatch(ours, valid_o), boxes_o, labels, co_l)
    p2 = draw_boxes(hatch(ref, valid_r), boxes_r, lab_r, co_r)
    p3 = Image.blend(ours, ref, 0.5)
    p4 = edge_diff(ours, ref, valid_both)
    S = 512
    tf = font(15)
    line_h = 19
    th = (len(table) + 3) * line_h + 20
    sheet = Image.new("RGB", (S * 4, S + 40 + th), (24, 24, 26))
    d = ImageDraw.Draw(sheet)
    hf = font(20)
    for i, (p, t) in enumerate(((p1, "ours"), (p2, "reference"), (p3, "50% overlay"), (p4, "edges: red ours / cyan ref / white both"))):
        sheet.paste(p.resize((S, S), Image.LANCZOS), (i * S, 40))
        d.text((i * S + 10, 10), t, fill=(235, 235, 240), font=hf)
    y = S + 50
    d.text((10, y), a.title or "%s  vs  %s" % (os.path.basename(a.ours), os.path.basename(a.ref)), fill=(235, 235, 240), font=tf)
    y += line_h + 6
    for line in table:
        col = (255, 120, 110) if line.rstrip().endswith("MISS") else (220, 220, 225)
        d.text((10, y), line, fill=col, font=tf)
        y += line_h
    sheet.save(a.out)
    base = os.path.splitext(a.out)[0]
    open(base + ".txt", "w").write("\n".join(table) + "\n")
    json.dump({"background": {"ours": hexc(bg_o), "ref": hexc(bg_r), "dE": round(bg_de, 2)}, "rows": data,
               "only_ours": un_o, "only_ref": un_r}, open(base + ".json", "w"), indent=1)
    print("\n".join(table))
    print("wrote", a.out)


if __name__ == "__main__":
    sys.exit(main())
