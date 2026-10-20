#!/usr/bin/env python3
"""HomePlay 圖示。顏色取自開機 hello 那一幕（深藍 → 藕紫 → 杏橘的晨昏漸層），主角是「島」的一雙眼睛。

  python3 tooling/make-icon.py            # 三個方向的設計稿 → .build/icon/sheet.png
  python3 tooling/make-icon.py --final A  # 定稿：assets/icon/AppIcon.icns + 官網圖示

全部用 4 倍超取樣畫，再縮回 1024，邊緣才乾淨。macOS 圖示格線：1024 畫布、824 主體、四周留 100。
"""
import os, subprocess, sys, shutil
from PIL import Image, ImageDraw, ImageFilter, ImageChops

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SS = 4                      # 超取樣倍數
N = 1024 * SS
TOP, MID, BOT = (58, 76, 124), (158, 134, 156), (216, 168, 124)   # hello 的晨昏三段
NAVY_HI, NAVY_LO = (96, 112, 140), (22, 32, 58)                   # 島的深色液態玻璃

def s(v): return int(round(v * SS))

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def gradient(w, h, stops):
    """直向多段漸層。stops = [(位置0–1, 顏色)…]"""
    col = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / (h - 1)
        for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
            if p0 <= t <= p1:
                col.putpixel((0, y), lerp(c0, c1, (t - p0) / (p1 - p0 or 1))); break
    return col.resize((w, h))

def rrect_mask(size, box, r):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=r, fill=255)
    return m

def dusk(w, h):
    """hello 的螢幕：晨昏漸層＋右上一團柔光＋兩道淡淡的弧。"""
    im = gradient(w, h, [(0, TOP), (0.45, MID), (1, BOT)]).convert("RGBA")
    glow = Image.new("L", (w, h), 0)
    ImageDraw.Draw(glow).ellipse((w * 0.48, h * 0.02, w * 1.02, h * 0.52), fill=120)
    glow = glow.filter(ImageFilter.GaussianBlur(w * 0.06))
    im = Image.composite(Image.new("RGBA", (w, h), (226, 200, 184, 255)), im, glow)
    arcs = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(arcs)
    for k, a in ((0, 70), (1, 40)):
        off = k * w * 0.035
        d.arc((-w * 0.35, h * 0.40 + off, w * 1.35, h * 1.6 + off), 200, 340, fill=(255, 255, 255, a), width=max(2, int(w * 0.012)))
    return Image.alpha_composite(im, arcs.filter(ImageFilter.GaussianBlur(w * 0.004)))

def eyes(w, h, look=(0.28, -0.22), squash=1.0):
    """一雙眼睛：白色橢圓＋黑眼珠（往右上看，好奇）＋高光。透明底，回傳 w×h。"""
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    ew, eh = w * 0.36, h * 0.92 * squash
    for cx in (w * 0.27, w * 0.73):
        cy = h / 2
        d.ellipse((cx - ew / 2, cy - eh / 2, cx + ew / 2, cy + eh / 2), fill=(250, 250, 248, 255))
        pw, ph = ew * 0.58, eh * 0.56
        px, py = cx + look[0] * (ew - pw) / 2 * 1.6, cy + look[1] * (eh - ph) / 2 * 1.6
        d.ellipse((px - pw / 2, py - ph / 2, px + pw / 2, py + ph / 2), fill=(18, 18, 22, 255))
        hx, hy, hr = px - pw * 0.16, py - ph * 0.2, pw * 0.17
        d.ellipse((hx - hr, hy - hr, hx + hr, hy + hr), fill=(255, 255, 255, 235))
    return im

def capsule(w, h):
    """島：深色液態玻璃膠囊，上緣一道亮邊，裡面一雙眼睛。"""
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    body = gradient(w, h, [(0, NAVY_HI), (0.45, (52, 64, 92)), (1, NAVY_LO)]).convert("RGBA")
    m = rrect_mask((w, h), (0, 0, w - 1, h - 1), h // 2)
    im.paste(body, (0, 0), m)
    rim = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle((0, 0, w - 1, h - 1), radius=h // 2, outline=(255, 255, 255, 110), width=max(2, h // 40))
    sheen = Image.new("L", (w, h), 0)
    ImageDraw.Draw(sheen).rounded_rectangle((w * 0.06, h * 0.06, w * 0.94, h * 0.42), radius=h // 4, fill=70)
    sheen = sheen.filter(ImageFilter.GaussianBlur(h * 0.05))
    im = Image.composite(Image.new("RGBA", (w, h), (255, 255, 255, 255)), im, ImageChops.multiply(sheen, m))
    im = Image.alpha_composite(im, rim)
    e = eyes(int(w * 0.40), int(h * 0.56))
    im.alpha_composite(e, (int((w - e.width) / 2), int((h - e.height) / 2 + h * 0.02)))
    return im

def shadow_under(canvas, mask, offset, blur, alpha):
    sh = Image.new("RGBA", canvas.size, (20, 24, 40, 0))
    a = mask.point(lambda v: v * alpha // 255).filter(ImageFilter.GaussianBlur(blur))
    sh.putalpha(ImageChops.offset(a, 0, offset))
    return Image.alpha_composite(canvas, sh)

def body_mask():
    return rrect_mask((N, N), (s(100), s(100), s(924), s(924)), s(186))

def option_a():
    """A　小螢幕：G4 白邊框＋黑框＋hello 的晨昏螢幕，中間是島與眼睛。像桌上那台的正面。"""
    c = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    bm = body_mask()
    c = shadow_under(c, bm, s(10), s(18), 90)
    white = gradient(N, N, [(0, (252, 252, 250)), (1, (226, 228, 230))]).convert("RGBA")
    c.paste(white, (0, 0), bm)
    bez = rrect_mask((N, N), (s(132), s(132), s(892), s(892)), s(156))
    c.paste(Image.new("RGBA", (N, N), (16, 16, 18, 255)), (0, 0), bez)
    sx0, sy0, sx1, sy1 = s(168), s(168), s(856), s(856)
    scr = dusk(sx1 - sx0, sy1 - sy0)
    c.paste(scr, (sx0, sy0), rrect_mask(scr.size, (0, 0, scr.width - 1, scr.height - 1), s(122)))
    cap = capsule(s(470), s(176))
    c.alpha_composite(cap, ((N - cap.width) // 2, s(512) - cap.height // 2 + s(12)))
    cam = s(9)
    ImageDraw.Draw(c).ellipse((N / 2 - cam, s(150) - cam, N / 2 + cam, s(150) + cam), fill=(44, 46, 52, 255))
    return c

def option_b():
    """B　整面晨昏：螢幕本身就是圖示，只留一雙大眼睛，沒有膠囊。最簡，遠看也認得。"""
    c = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    bm = body_mask()
    c = shadow_under(c, bm, s(10), s(18), 90)
    scr = dusk(s(824), s(824))
    c.paste(scr, (s(100), s(100)), rrect_mask(scr.size, (0, 0, scr.width - 1, scr.height - 1), s(186)))
    e = eyes(s(520), s(300), look=(0.32, -0.26))
    glow = e.split()[3].filter(ImageFilter.GaussianBlur(s(14)))
    halo = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    halo.paste(Image.new("RGBA", e.size, (255, 236, 220, 120)), ((N - e.width) // 2, s(540) - e.height // 2), glow)
    c = Image.alpha_composite(c, halo)
    c.alpha_composite(e, ((N - e.width) // 2, s(540) - e.height // 2))
    return c

def option_c():
    """C　桌上那台：淺色底上一台小 HomeView（螢幕＋圓底座），螢幕裡是島。強調「桌寵」。"""
    c = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    bm = body_mask()
    c = shadow_under(c, bm, s(10), s(18), 80)
    bg = gradient(N, N, [(0, (238, 240, 244)), (1, (214, 218, 226))]).convert("RGBA")
    c.paste(bg, (0, 0), bm)
    d = ImageDraw.Draw(c)
    d.rounded_rectangle((s(392), s(660), s(632), s(760)), radius=s(40), fill=(232, 233, 235, 255), outline=(200, 203, 208, 255), width=s(3))
    dev = rrect_mask((N, N), (s(212), s(206), s(812), s(706)), s(118))
    c = shadow_under(c, dev, s(14), s(16), 70)
    c.paste(Image.new("RGBA", (N, N), (250, 250, 249, 255)), (0, 0), dev)
    c.paste(Image.new("RGBA", (N, N), (16, 16, 18, 255)), (0, 0), rrect_mask((N, N), (s(230), s(224), s(794), s(688)), s(102)))
    scr = dusk(s(528), s(428))
    c.paste(scr, (s(248), s(242)), rrect_mask(scr.size, (0, 0, scr.width - 1, scr.height - 1), s(86)))
    cap = capsule(s(330), s(124))
    c.alpha_composite(cap, ((N - cap.width) // 2, s(456) - cap.height // 2))
    return c

def finish(img):
    return img.resize((1024, 1024), Image.LANCZOS)

def main():
    out = os.path.join(ROOT, ".build", "icon"); os.makedirs(out, exist_ok=True)
    opts = {"A": option_a, "B": option_b, "C": option_c}
    if "--final" in sys.argv:
        k = sys.argv[sys.argv.index("--final") + 1]
        icon = finish(opts[k]())
        dst = os.path.join(ROOT, "assets", "icon"); os.makedirs(dst, exist_ok=True)
        icon.save(os.path.join(dst, "AppIcon-1024.png"))
        iset = os.path.join(out, "AppIcon.iconset"); shutil.rmtree(iset, ignore_errors=True); os.makedirs(iset)
        for px in (16, 32, 128, 256, 512):
            icon.resize((px, px), Image.LANCZOS).save(os.path.join(iset, f"icon_{px}x{px}.png"))
            icon.resize((px * 2, px * 2), Image.LANCZOS).save(os.path.join(iset, f"icon_{px}x{px}@2x.png"))
        subprocess.run(["iconutil", "-c", "icns", iset, "-o", os.path.join(dst, "AppIcon.icns")], check=True)
        media = os.path.join(ROOT, "site", "public", "media")
        # 官網：分頁圖示用透明底，apple-touch 要不透明（iOS 自己裁圓角），取主體那塊放滿
        # 網頁不需要 macOS 的四周留白與陰影：只取圓角方塊主體（圓角外透明），分頁、頁首才不會顯得小
        body = opts[k]()
        body.putalpha(ImageChops.multiply(body.split()[3], body_mask()))
        body = body.crop((s(100), s(100), s(924), s(924)))
        for px in (192, 512):
            body.resize((px, px), Image.LANCZOS).save(os.path.join(media, f"icon-{px}.png"), optimize=True)
        sq = body.resize((180, 180), Image.LANCZOS)
        bg = gradient(180, 180, [(0, TOP), (0.45, MID), (1, BOT)]); bg.paste(sq, (0, 0), sq)  # 圓角外墊同色，iOS 裁圓角不露縫
        bg.save(os.path.join(media, "apple-touch-icon.png"), optimize=True)
        print(f"定稿 {k}：assets/icon/AppIcon.icns、AppIcon-1024.png、site/public/media/icon-192.png、icon-512.png、apple-touch-icon.png")
        return
    imgs = {k: finish(f()) for k, f in opts.items()}
    for k, im in imgs.items(): im.save(os.path.join(out, f"option-{k}.png"))
    # 設計稿：三個方向各一列，1024／128／32 三種大小，淺深兩種底
    W, H = 1500, 3 * 420 + 40
    sheet = Image.new("RGB", (W, H), (246, 247, 249))
    d = ImageDraw.Draw(sheet)
    for r, (k, im) in enumerate(imgs.items()):
        y = 20 + r * 420
        sheet.paste(Image.new("RGB", (W // 2, 400), (30, 32, 36)), (W // 2, y))
        for half, x0 in ((0, 20), (1, W // 2 + 20)):
            big = im.resize((380, 380), Image.LANCZOS); sheet.paste(big, (x0, y + 10), big)
            xx = x0 + 410
            for px in (128, 64, 32, 16):
                sm = im.resize((px, px), Image.LANCZOS); sheet.paste(sm, (xx, y + 200 - px // 2), sm); xx += px + 24
        d.text((24, y + 4), k, fill=(120, 120, 120))
    dst = os.path.join(ROOT, "docs", "design-drafts", "圖示設計稿.png")
    sheet.save(dst)
    print(dst)

main()
