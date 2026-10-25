#!/usr/bin/env python3
"""2.0 hello：把六台機身各自逐格拍的 PNG（HelloProduct，--hello-product）排成參考影片那種 2×3 的版面。

    python3 tooling/hello-composite.py OUT_DIR silver gray starlight rose wall-silver wall-gray [--stagger 0] [--size 1500]

每個輸入資料夾是一台機身的 000.png…222.png（透明底）。版面照參考影片量的（1500² 畫布）：
螢幕高 266 px，中心在 (402, 239)、(1102, 239)、(402, 721)、(1103, 721)、(403, 1256)、(1103, 1255)；底色 #EEEEEE。
每台的縮放與位置用它自己最後一格的螢幕外框（亮的暖色像素）對齊，整段不變（鏡頭沒動）。
--stagger N：第 i 台晚 N×i 格（參考影片量到 0 格；官網版可以給 2 格＝67 ms）。
輸出 OUT_DIR/000.png…，再用 ffmpeg 接成 MP4（指令見 docs/plans/hello.md）。只用 Pillow。
"""
import argparse
import os
import sys

from PIL import Image

CENTRES = [(402, 239), (1102, 239), (402, 721), (1103, 721), (403, 1256), (1103, 1255)]
SCREEN_H = 266
BG = (0xEE, 0xEE, 0xEE)


def screen_box(img):
    """亮起的螢幕：飽和、夠亮的暖色像素的外框（用 1/2 解析度掃）"""
    im = img.convert("RGB")
    w, h = im.size
    small = im.resize((w // 2, h // 2))
    px = small.load()
    xs, ys = [], []
    for y in range(small.size[1]):
        for x in range(small.size[0]):
            r, g, b = px[x, y]
            mx, mn = max(r, g, b), min(r, g, b)
            if mx > 150 and (mx - mn) / mx > 0.35 and r >= b:
                xs.append(x)
                ys.append(y)
    if len(xs) < 50:
        return None
    xs.sort()
    ys.sort()
    k = len(xs) // 100
    return (xs[k] * 2, ys[k] * 2, xs[-1 - k] * 2, ys[-1 - k] * 2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("units", nargs=6)
    ap.add_argument("--stagger", type=float, default=0)
    ap.add_argument("--size", type=int, default=1500)
    ap.add_argument("--frames", type=int, default=223)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    k = a.size / 1500
    fits = []
    for d in a.units:
        last = sorted(f for f in os.listdir(d) if f.endswith(".png"))[-1]
        img = Image.open(os.path.join(d, last))
        box = screen_box(img)
        if box is None:
            sys.exit(f"{d}/{last}: 找不到亮起的螢幕")
        s = SCREEN_H * k / (box[3] - box[1])
        fits.append((s, ((box[0] + box[2]) / 2, (box[1] + box[3]) / 2)))
        print(f"{d}: screen {box} scale {s:.3f}")
    for n in range(a.frames):
        canvas = Image.new("RGBA", (a.size, a.size), BG + (255,))
        for i, d in enumerate(a.units):
            m = max(0, min(a.frames - 1, round(n - a.stagger * i)))
            p = os.path.join(d, f"{m:03d}.png")
            if not os.path.exists(p):
                continue
            img = Image.open(p).convert("RGBA")
            s, (cx, cy) = fits[i]
            img = img.resize((round(img.width * s), round(img.height * s)), Image.LANCZOS)
            tx, ty = CENTRES[i]
            canvas.paste(img, (round(tx * k - cx * s), round(ty * k - cy * s)), img)   # 畫布不透明：paste 帶遮罩就是 over
        canvas.convert("RGB").save(os.path.join(a.out, f"{n:03d}.png"))
    print(f"{a.frames} frames -> {a.out}")


if __name__ == "__main__":
    main()
