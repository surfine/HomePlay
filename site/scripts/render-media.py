#!/usr/bin/env python3
"""用 homeplay-pet --snapshot 拍官網全部真機渲染，裁成共用邊界後轉 WebP 到 public/media/renders/。

  python3 scripts/render-media.py            # 全拍
  python3 scripts/render-media.py faces      # 只拍某一組
  python3 scripts/render-media.py --lang en  # 英文屏幕，輸出到 renders/en/（官網 /en/ 用）

同一組（例如十個表情）共用一個裁切框，網頁上疊圖切換時機身不會跳。
表情／外觀／夜晚這幾組會在同一個行程裡多拍「瞄一眼」「閉眼」兩張，只差眼睛；
轉成一張全尺寸透明疊圖（fx/），官網在原本的靜態圖上做眨眼與眼神動畫。
"""
import math, os, subprocess, sys, tempfile, time
from PIL import Image, ImageChops

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "public", "media", "renders")
HERO = ["--yaw", "0.28", "--pitch", "0.1", "--near", "--hour", "10", "--pointer", "0,0"]
FACES = "idle happy love wink thinking annoyed surprised worried sleepy asleep".split()

GROUPS = {
    "faces": [(f"face-{f}", ["--finish", "g4", "--face", f, "--time", "10:09", *HERO]) for f in FACES],   # 固定 10:09：十張一樣，不必等整分鐘
    "finish": [(f"finish-{f}", ["--finish", f, "--face", "curious", *HERO])
               for f in "g4 silver starlight rose gray".split()],
    "views": [
        ("view-front", ["--finish", "g4", "--face", "idle", "--yaw", "0", "--pitch", "0", "--near"]),
        ("view-side", ["--finish", "silver", "--face", "idle", "--yaw", "1.45", "--pitch", "0.05", "--near"]),
        ("view-back", ["--finish", "silver", "--face", "idle", "--yaw", "3.0", "--pitch", "0.12", "--near"]),
        ("view-apart", ["--finish", "silver", "--face", "surprised", "--apart"]),
    ],
    "moments": [
        ("hello", ["--finish", "g4", "--yaw", "0.28", "--pitch", "0.1", "--near", "--hello", "--snapshot-at", "2.2"]),
        ("ambient-night", ["--finish", "gray", "--face", "idle", "--yaw", "0.28", "--pitch", "0.1", "--hour", "22", "--time", "23:12"]),
        ("asleep-night", ["--finish", "gray", "--face", "asleep", "--yaw", "0.28", "--pitch", "0.1", "--hour", "2", "--time", "02:07"]),
    ],
    # 錶面一覽：正面、同一個時間（10:09，像 Apple 的產品圖），八款各一張
    "styles": [(f"style-{st}", ["--finish", "silver", "--face", "idle", "--style", st, "--clock", "bold", "--yaw", "0", "--pitch", "0.04",
                                "--near", "--hour", "16", "--time", "10:09", "--pointer", "0,0"])
               for st in "island flow modular analog weather calendar growth system6".split()],
    # 轉一圈：每 10° 一張，官網拖動／捲動時逐張換
    "spin": [(f"spin/{i:02d}", ["--finish", "g4", "--face", "idle", "--yaw", f"{i * 2 * math.pi / 36:.4f}", "--pitch", "0.1", "--near", "--hour", "10"])
             for i in range(36)],
    # 開機寫 hello 的過程：0.3–1.95 秒，寫完就停（之後會淡出換成時鐘）。跟語言無關，只拍一套
    "hello-seq": [(f"hello/{i:02d}", ["--finish", "g4", "--yaw", "0.28", "--pitch", "0.1", "--near", "--hello", "--snapshot-at", f"{0.3 + i * 0.11:.2f}"])
                  for i in range(16)],
}
SHARED_BOX = ("faces", "finish", "spin", "hello-seq", "styles")   # 這些組逐張疊放，要共用裁切框，機身才不會跳
WIDTH = {"faces": 1200, "finish": 1200, "spin": 640, "hello-seq": 640, "styles": 640}
# 只有這些表情拍眨眼／瞄一眼；睡著已經閉眼、眨眼沒有意義
NO_BLINK = {"face-asleep"}
NO_GLANCE = {"face-asleep", "face-wink"}
# 眼神只在這張圖的「島」附近變；把差異限制在此，避免機身抗鋸齒的微小差別被收進疊圖
EYE_BOX = (0.20, 0.36, 0.80, 0.64)

LANG = None
WEATHER_JSON = '{"temp":22,"hi":25,"lo":19,"code":2,"wind":11,"humidity":76,"aqi":21,"sunset":"17:21","city":"臺北市"}'

def shoot(path, args, env=None):
    # 錶面樣式會被桌寵記在偏好裡（HomePlayFaceStyle），官網一律拍島錶面
    extra = ([] if "--style" in args else ["--style", "island"]) + (["--lang", LANG] if LANG else [])
    if "style-weather" in os.path.basename(path):  # 天氣錶面：固定的假資料，不依賴網路
        env = dict(env or os.environ, HOMEPLAY_WEATHER_JSON=WEATHER_JSON)
    for attempt in range(3):   # 機器忙時偶爾等不到第一張圖：最多重拍兩次
        if subprocess.run([os.path.join(HERE, "shoot.sh"), path, *args, *extra], env=env).returncode == 0:
            return
    raise RuntimeError(f"shoot failed 3 times: {path}")

def paired(name, group):
    return group == "faces" and name not in NO_BLINK or group == "finish" or name == "ambient-night"

def shoot_pair(tmp, name, args):
    stem = os.path.join(tmp, name.replace("/", "-"))
    openp, gp, bp = stem + "-open.png", stem + "-glance.png", stem + "-blink.png"
    env = os.environ.copy()
    if name not in NO_GLANCE: env["SHOOT_GLANCE"] = gp
    if name not in NO_BLINK: env["SHOOT_BLINK"] = bp
    shoot(openp, args, env=env)
    return openp, (gp if os.path.exists(gp) else None), (bp if os.path.exists(bp) else None)

def overlay(open_im, alt_im, pad=14):
    """把 alt 與 open 不同的眼睛區域，貼到一張同尺寸的透明畫布上。

    open 與 alt 出自同一個 homeplay-pet 行程、同一台相機，只差眨眼／眼珠；
    貼回去時眼睛底下的玻璃背景與原圖逐像素一致，疊圖不會有鬼影。
    """
    w, h = open_im.size
    clamp = (int(w * EYE_BOX[0]), int(h * EYE_BOX[1]), int(w * EYE_BOX[2]), int(h * EYE_BOX[3]))
    diff = ImageChops.difference(open_im.convert("RGB"), alt_im.convert("RGB")).crop(clamp)
    bbox = diff.getbbox()
    if not bbox: return None
    box = (max(0, clamp[0] + bbox[0] - pad), max(0, clamp[1] + bbox[1] - pad),
           min(w, clamp[0] + bbox[2] + pad), min(h, clamp[1] + bbox[3] + pad))
    canvas = Image.new("RGBA", open_im.size, (0, 0, 0, 0))
    canvas.paste(alt_im.crop(box), box)
    return canvas

def save_webp(im, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    png = dst[:-5] + ".png"
    im.save(png)
    subprocess.run(["cwebp", "-quiet", "-q", "86", "-alpha_q", "100", png, "-o", dst], check=True)
    os.remove(png)
    print(f"{os.path.relpath(dst, os.path.join(HERE, '..'))} {im.width}x{im.height} {os.path.getsize(dst)//1024} KB")

def main():
    global LANG, OUT
    argv = sys.argv[1:]
    LANG = "zh-Hant"  # 中文官網是台灣正體
    if "--lang" in argv:
        i = argv.index("--lang"); LANG = argv[i + 1]; del argv[i:i + 2]
        if LANG != "zh-Hant":
            OUT = os.path.join(OUT, LANG)
    want = argv or list(GROUPS)
    os.makedirs(OUT, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="homeplay-shots-")
    for g in want:
        order = GROUPS[g]
        if g == "spin":  # 螢幕朝前的那幾張要在同一分鐘拍完，轉回原點時鐘才不會跳：整分鐘一開始先拍它們
            front = {31, 32, 33, 34, 35, 0, 1, 2, 3, 4}
            order = [x for i, x in enumerate(order) if i in front] + [x for i, x in enumerate(order) if i not in front]
            while time.localtime().tm_sec > 5:
                time.sleep(1)
        shots = []
        for name, args in order:
            if paired(name, g):
                shots.append((name, *shoot_pair(tmp, name, args)))
            else:
                p = os.path.join(tmp, name.replace("/", "-") + ".png"); shoot(p, args)
                shots.append((name, p, None, None))
        opens = [(n, Image.open(p)) for n, p, _, _ in shots]
        if g in SHARED_BOX:
            boxes = [im.getchannel("A").getbbox() for _, im in opens]
            box = (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes))
        w = WIDTH.get(g, 900)
        # hello 逐格跟語言無關，只留一份（/en/ 與 /zh-Hans/ 共用）
        outdir = os.path.join(OUT, "..") if (g == "hello-seq" and LANG != "zh-Hant") else OUT
        for name, openp, gp, bp in shots:
            box = box if g in SHARED_BOX else Image.open(openp).getchannel("A").getbbox()
            def crop(im):
                im = im.crop(box)
                if im.width > w: im = im.resize((w, round(im.height * w / im.width)), Image.LANCZOS)
                return im
            base = crop(Image.open(openp))
            save_webp(base, os.path.join(outdir, name + ".webp"))
            fxname = name.replace("/", "-")
            for kind, path in (("glance", gp), ("blink", bp)):
                if not path: continue
                ov = overlay(base, crop(Image.open(path)))
                if ov is None: continue
                save_webp(ov, os.path.join(OUT, "fx", f"{kind}-{fxname}.webp"))

main()
