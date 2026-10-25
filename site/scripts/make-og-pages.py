#!/usr/bin/env python3
"""兩張子頁的分享卡片（1200×630 JPEG），每種語言一張：
  og-preview-<語言>.jpg：2.0 Preview。夜色底、右邊是現拍的機身產品照（public/media/2.0/<語言>/prod-home-1100.webp）、左邊 Preview 標記與標題。
  og-history-<語言>.jpg：小工具往事。冷白底、左邊札記編號與標題、右邊一欄年份（最後一年用夕照漸層）。
標題取自 preview.mjs／history.mjs；字體用 macOS 系統字（PingFang、SF）。用法：python3 -I scripts/make-og-pages.py"""
import glob, json, os, subprocess
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
MEDIA = os.path.join(ROOT, "public", "media")
W, H = 1200, 630
GLOW = [(255, 159, 107), (240, 112, 142), (143, 124, 247)]   # 與 preview.css 的 --glow 同一組
LANGS = ["zh-Hant", "zh-Hans", "en"]

def strings():
    js = ("Promise.all([import('./preview.mjs'),import('./history.mjs')]).then(([p,h])=>console.log(JSON.stringify("
          "Object.fromEntries(['zh-Hant','zh-Hans','en'].map(k=>[k,{h1:p.preview[k].h1,kicker:h.history[k].kicker,title:h.history[k].h1}])))))")
    out = subprocess.run(["node", "-e", js], cwd=os.path.join(ROOT, "scripts"), check=True, capture_output=True, text=True).stdout
    return json.loads(out)

def font(lang, size, weight="semibold", mono=False):
    if mono:
        for p in ["/System/Library/Fonts/SFNSMono.ttf", "/System/Library/Fonts/Menlo.ttc"]:
            if os.path.exists(p):
                f = ImageFont.truetype(p, size)
                try: f.set_variation_by_name("Semibold")
                except Exception: pass
                return f
    if lang.startswith("zh"):
        cands = glob.glob("/System/Library/AssetsV2/com_apple_MobileAsset_Font*/*/AssetData/PingFang.ttc") + [
            "/System/Library/PrivateFrameworks/FontServices.framework/Versions/A/Resources/Reserved/PingFangUI.ttc", "/System/Library/Fonts/Hiragino Sans GB.ttc"]
        want = ["pingfang tc" if lang == "zh-Hant" else "pingfang sc", weight]
        for p in cands:
            if not os.path.exists(p): continue
            for i in range(40):
                try: f = ImageFont.truetype(p, size, index=i)
                except Exception: break
                if all(w in " ".join(f.getname()).lower() for w in want): return f
            return ImageFont.truetype(p, size)
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    try: f.set_variation_by_name(weight.capitalize())
    except Exception: pass
    return f

def gradient(w, h):
    """水平三色漸層（夕照），回傳 RGB 圖。"""
    g = Image.new("RGB", (w, 1))
    for x in range(w):
        t = x / max(1, w - 1) * 2
        a, b = (GLOW[0], GLOW[1]) if t < 1 else (GLOW[1], GLOW[2])
        u = t if t < 1 else t - 1
        g.putpixel((x, 0), tuple(round(a[i] + (b[i] - a[i]) * u) for i in range(3)))
    return g.resize((w, h))

def glow_text(im, xy, text, f):
    """用漸層填字：先畫遮罩，再把漸層貼進去。"""
    d = ImageDraw.Draw(im)
    l, t, r, b = d.textbbox(xy, text, font=f)
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).text(xy, text, font=f, fill=255)
    im.paste(gradient(r - l + 2, b - t + 2), (l, t), mask.crop((l, t, r + 2, b + 2)))

def pill(im, x, y, text, f):
    d = ImageDraw.Draw(im)
    w = round(d.textlength(text, font=f)) + 36
    h = 44
    m = Image.new("L", (w, h), 0); ImageDraw.Draw(m).rounded_rectangle((0, 0, w - 1, h - 1), radius=h // 2, fill=255)
    im.paste(gradient(w, h), (x, y), m)
    d.text((x + 18, y + h / 2), text, font=f, fill=(255, 255, 255), anchor="lm")
    return w

def split_lines(h1):
    """preview.mjs 的 h1 是兩個 <span class="l">；拆回兩行純文字。"""
    import re
    return [re.sub(r"<[^>]+>", "", s).strip() for s in re.findall(r'<span class="l[^"]*">(.*?)</span>', h1)]

def preview_card(lang, s):
    im = Image.new("RGB", (W, H), (7, 8, 10))
    # 右下一團夕照光暈
    halo = Image.new("L", (W, H), 0)
    ImageDraw.Draw(halo).ellipse((620, 260, 1320, 900), fill=120)
    from PIL import ImageFilter
    halo = halo.filter(ImageFilter.GaussianBlur(120))
    im.paste(gradient(W, H), (0, 0), halo)
    prod = Image.open(os.path.join(MEDIA, "2.0", lang, "prod-home-1100.webp")).convert("RGBA")
    ph = 600; pw = round(prod.width * ph / prod.height)
    prod = prod.resize((pw, ph), Image.LANCZOS)
    im.paste(prod, (W - pw - 40, 30), prod)
    d = ImageDraw.Draw(im)
    x = 72
    icon = Image.open(os.path.join(MEDIA, "icon-192.png")).convert("RGBA").resize((44, 44), Image.LANCZOS)
    im.paste(icon, (x, 60), icon)
    d.text((x + 56, 82), "HomePlay", font=font("en", 30), fill=(245, 245, 247), anchor="lm")
    pill(im, x, 168, "Preview", font("en", 24))
    d.text((x, 236), "HomePlay 2.0", font=font("en", 76, "bold"), fill=(245, 245, 247))
    l1, l2 = split_lines(s["h1"])
    f = font(lang, 40 if lang.startswith("zh") else 38)
    d.text((x, 350), l1, font=f, fill=(161, 166, 174))
    glow_text(im, (x, 404), l2, f)
    im.save(os.path.join(MEDIA, f"og-preview-{lang}.jpg"), "JPEG", quality=88, optimize=True)

def wrap(d, text, f, width, lang):
    units = list(text) if lang.startswith("zh") else text.split(" ")
    sep = "" if lang.startswith("zh") else " "
    lines, cur = [], ""
    for u in units:
        t = (cur + sep + u) if cur else u
        if d.textlength(t, font=f) <= width: cur = t
        else: lines.append(cur); cur = u
    if cur: lines.append(cur)
    return lines

def history_card(lang, s):
    im = Image.new("RGB", (W, H), (236, 238, 241))
    d = ImageDraw.Draw(im)
    x = 72
    icon = Image.open(os.path.join(MEDIA, "icon-192.png")).convert("RGBA").resize((44, 44), Image.LANCZOS)
    im.paste(icon, (x, 60), icon)
    d.text((x + 56, 82), "HomePlay", font=font("en", 30), fill=(21, 24, 28), anchor="lm")
    badge = s["kicker"].split(" · ")[0].replace("HomePlay ", "")
    pill(im, x, 168, badge, font(lang, 24))
    f = font(lang, 60 if lang.startswith("zh") else 56, "semibold" if lang.startswith("zh") else "bold")
    title = s["title"]
    if lang.startswith("zh") and "，" in title:
        i = title.find("，") + 1; lines = [title[:i], title[i:]]
    else:
        lines = wrap(d, title, f, 640, lang)
    y = 244
    for ln in lines:
        d.text((x, y), ln, font=f, fill=(21, 24, 28)); y += round(f.size * 1.3)
    d.text((x, y + 16), s["kicker"].split(" · ", 1)[1], font=font(lang, 28, "regular"), fill=(91, 98, 107))
    # 右邊：一欄年份，細線相連，最後一年是夕照色
    years = ["1984", "1997", "2003", "2007", "2015", "2026"]
    mf = font("en", 40, mono=True)
    yy = 92
    for i, yr in enumerate(years):
        if i: d.line((1040, yy - 30, 1040, yy - 12), fill=(196, 200, 206), width=2)
        if i == len(years) - 1: glow_text(im, (980, yy), yr, mf)
        else: d.text((980, yy), yr, font=mf, fill=(120, 126, 135))
        yy += 84
    im.save(os.path.join(MEDIA, f"og-history-{lang}.jpg"), "JPEG", quality=88, optimize=True)

S = strings()
for lang in LANGS:
    preview_card(lang, S[lang])
    history_card(lang, S[lang])
print("ok")
