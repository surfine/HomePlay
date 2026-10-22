#!/usr/bin/env python3
"""GitHub README 的拼圖：全部取自官網那套現拍渲染（site/public/media/renders/），不另外畫。

  python3 tooling/make-readme-media.py            # 輸出 assets/github/{grid,faces,styles,finishes}-v2.webp
  python3 tooling/make-readme-media.py --lang zh-Hans

卡片底色、圓角、間距照 v1；表情改成兩排五張（v1 一排十張在手機上太小）。
"""
import os, subprocess, sys
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "github")
BG, CARD, DARK = (236, 238, 241), (245, 246, 248), (16, 17, 22)


def renders(lang):
    base = os.path.join(ROOT, "site", "public", "media", "renders")
    sub = os.path.join(base, lang) if lang and lang != "zh-Hant" else base
    return sub if os.path.exists(os.path.join(sub, "face-idle.webp")) else base


def card(canvas, box, color=CARD, radius=40):
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle(box, radius=radius, fill=color)


def place(canvas, img, box, pad=0.08):
    """等比塞進 box（留邊），置中；透明底直接疊。"""
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    k = min(w * (1 - 2 * pad) / img.width, h * (1 - 2 * pad) / img.height)
    im = img.resize((max(1, round(img.width * k)), max(1, round(img.height * k))), Image.LANCZOS)
    canvas.alpha_composite(im, (x0 + (w - im.width) // 2, y0 + (h - im.height) // 2))


def grid(cells, cols, cell, gap, margin, dark=()):
    rows = (len(cells) + cols - 1) // cols
    W = margin * 2 + cols * cell[0] + (cols - 1) * gap
    H = margin * 2 + rows * cell[1] + (rows - 1) * gap
    c = Image.new("RGBA", (W, H), BG + (255,))
    for i, img in enumerate(cells):
        x = margin + (i % cols) * (cell[0] + gap)
        y = margin + (i // cols) * (cell[1] + gap)
        box = (x, y, x + cell[0], y + cell[1])
        card(c, box, DARK if i in dark else CARD)
        place(c, img, box)
    return c


def save(im, name):
    png = os.path.join(OUT, name[:-5] + ".png")
    im.convert("RGB").save(png)
    subprocess.run(["cwebp", "-quiet", "-q", "86", png, "-o", os.path.join(OUT, name)], check=True)
    os.remove(png)
    print(name, im.size)


def main():
    lang = sys.argv[sys.argv.index("--lang") + 1] if "--lang" in sys.argv else "zh-Hans"
    R = renders(lang)
    open_ = lambda n: Image.open(os.path.join(R, n)).convert("RGBA")
    carplay = Image.open(os.path.join(ROOT, "site", "public", "media", "carplay-music.png")).convert("RGBA")
    save(grid([open_("view-front.webp"), open_("view-back.webp"), carplay, open_("view-apart.webp")],
              2, (740, 540), 40, 40, dark={2}), "grid-v2.webp")
    faces = "idle curious happy focus sleepy asleep surprised worried love wink".split()
    save(grid([open_(f"face-{f}.webp") for f in faces], 5, (380, 420), 16, 20), "faces-v2.webp")
    styles = "island flow modular analog pocket bedside".split()
    save(grid([open_(f"style-{s}.webp") for s in styles], 3, (560, 600), 20, 24), "styles-v2.webp")
    finishes = "g4 silver starlight rose gray".split()
    save(grid([open_(f"finish-{f}.webp") for f in finishes], 5, (340, 400), 16, 20), "finishes-v2.webp")


main()
