#!/usr/bin/env python3
"""產生分享圖：og-v4.jpg（繁中）/ og-zh-hans-v4.jpg（简中）/ og-en-v4.jpg（1200x630），以及 share-square.jpg（512x512，給只抓頁內第一張大圖的 IM）。
標題取自 content.mjs 的 ogTitle；素材取自 public/media/renders（各語言各一套屏幕），字體用 macOS 系統字（找不到就退回 PIL 內建字，版面仍可用）。
用法：python3 scripts/make-og.py"""
import glob, json, os, subprocess
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
MEDIA = os.path.join(ROOT, "public", "media")
R = os.path.join(MEDIA, "renders")
BG = (236, 238, 241)
INK = (21, 24, 28)
MUTED = (91, 98, 107)

def titles():
    """從 content.mjs 讀每種語言的 ogTitle（文案只有一份）。"""
    js = "import('./content.mjs').then(m=>console.log(JSON.stringify(Object.fromEntries(Object.entries(m.copy).map(([k,c])=>[k,c.ogTitle])))))"
    out = subprocess.run(["node", "-e", js], cwd=os.path.join(ROOT, "scripts"), check=True, capture_output=True, text=True).stdout
    return json.loads(out)

def pick(path, want):
    """在 ttc/ttf 裡挑名稱含 want 的字面；挑不到就用第 0 個。"""
    for i in range(40):
        try:
            f = ImageFont.truetype(path, 40, index=i)
        except Exception:
            break
        name = " ".join(f.getname()).lower()
        if all(w in name for w in want):
            return i
    return 0

def font(kind, size, tc=True):
    if kind == "zh":
        cands = glob.glob("/System/Library/AssetsV2/com_apple_MobileAsset_Font*/*/AssetData/PingFang.ttc")
        cands += ["/System/Library/PrivateFrameworks/FontServices.framework/Versions/A/Resources/Reserved/PingFangUI.ttc",
                  "/System/Library/Fonts/Hiragino Sans GB.ttc"]
        want = ["pingfang tc" if tc else "pingfang sc", "semibold"]
    else:
        cands = ["/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"]
        want = []
    for p in cands:
        if os.path.exists(p):
            try:
                idx = pick(p, want) if want else 0
                f = ImageFont.truetype(p, size, index=idx)
                if kind == "en" and p.endswith("SFNS.ttf"):
                    try:
                        f.set_variation_by_name("Semibold")
                    except Exception:
                        pass
                return f
            except Exception:
                continue
    return ImageFont.load_default()

def wrap(draw, text, f, width, kind):
    """中文逐字折行，英文逐詞折行。"""
    units = list(text) if kind == "zh" else text.split(" ")
    sep = "" if kind == "zh" else " "
    lines, cur = [], ""
    for u in units:
        t = (cur + sep + u) if cur else u
        if draw.textlength(t, font=f) <= width:
            cur = t
        else:
            lines.append(cur)
            cur = u
    if cur:
        lines.append(cur)
    return lines

def card(kind, headline, sub, out, renders="", tc=True):
    W, H = 1200, 630
    im = Image.new("RGB", (W, H), BG)
    rdir = os.path.join(R, renders)
    if not os.path.exists(os.path.join(rdir, "og-pet.webp")) and not os.path.exists(os.path.join(rdir, "face-curious.webp")):
        rdir = R  # 該語言的屏幕還沒拍：先用繁中那套
    pet_name = "og-pet.webp" if os.path.exists(os.path.join(rdir, "og-pet.webp")) else "face-curious.webp"
    pet = Image.open(os.path.join(rdir, pet_name)).convert("RGBA")
    ph = 560
    pw = round(pet.width * ph / pet.height)
    pet = pet.resize((pw, ph), Image.LANCZOS)
    im.paste(pet, (W - pw - 56, (H - ph) // 2 + 6), pet)
    d = ImageDraw.Draw(im)
    x = 72
    hf = font(kind, 66 if kind == "zh" else 68, tc)
    if kind == "zh":  # 在第一個逗號後斷成兩行
        i = headline.find("，") + 1
        lines = [headline[:i], headline[i:]] if i else wrap(d, headline, hf, 540, kind)
    else:
        lines = wrap(d, headline, hf, 540, kind)
    # 標題放不下就多折一行（中文在逗號後、再在「帶到／带到」前；英文逐詞），字號維持
    room = W - pw - 56 - 40 - x
    size = 62 if kind == "zh" else 60
    hf = font(kind, size, tc)
    if kind == "zh":
        lines = [ln for part in lines for ln in ([part[:part.find("帶到")], part[part.find("帶到"):]] if "帶到" in part and d.textlength(part, font=hf) > room
                                               else [part[:part.find("带到")], part[part.find("带到"):]] if "带到" in part and d.textlength(part, font=hf) > room else [part])]
        lines = [ln.strip() for ln in lines]
    else:
        lines = wrap(d, headline, hf, room, kind)
    lh = round(size * (88 / 66 if kind == "zh" else 80 / 68))
    y = 200 - (len(lines) - 2) * 44
    for ln in lines:
        d.text((x, y), ln, font=hf, fill=INK)
        y += lh
    sf = font(kind, 28, tc)
    d.text((x, y + 20), sub, font=sf, fill=MUTED)
    # 左上：圖示 + HomePlay 字標
    bf = font(kind, 30, tc)
    icon = Image.open(os.path.join(MEDIA, "icon-192.png")).convert("RGBA").resize((44, 44), Image.LANCZOS)
    im.paste(icon, (x, 56), icon)
    d.text((x + 56, 62), "HomePlay", font=bf, fill=INK)
    im.save(os.path.join(MEDIA, out), "JPEG", quality=90, optimize=True)

T = titles()
card("zh", T["zh-Hant"], "Mac 上的 3D HomeView 桌寵", "og-v4.jpg", "", tc=True)
card("zh", T["zh-Hans"], "Mac 上的 3D HomeView 桌宠", "og-zh-hans-v4.jpg", "zh-Hans", tc=False)
card("en", T["en"], "A 3D HomeView desktop pet for Mac", "og-en-v4.jpg", "en")

# 方形分享圖：不透明 512x512，圖示置中約 78%，底色同網站背景
sq = Image.new("RGB", (512, 512), BG)
ic = Image.open(os.path.join(MEDIA, "icon-512.png")).convert("RGBA")
n = round(512 * 0.78)
ic = ic.resize((n, n), Image.LANCZOS)
sq.paste(ic, ((512 - n) // 2, (512 - n) // 2), ic)
sq.save(os.path.join(MEDIA, "share-square.jpg"), "JPEG", quality=90, optimize=True)

# 圖示由 tooling/make-icon.py --final 輸出（icon-192.png、icon-512.png、apple-touch-icon.png）
print("ok")
