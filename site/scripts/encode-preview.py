#!/usr/bin/env python3
"""2.0 Preview 頁的素材：把 homeplay-pet 現拍的 PNG 轉成 AVIF + WebP（兩種寬度）。

用法（-I 隔離）：python3 -I scripts/encode-preview.py <渲染資料夾>
渲染資料夾裡每種語言一個子資料夾（zh-Hant／zh-Hans／en），檔名照 SCREENS 與 PROD。產出在 public/media/2.0/<語言>/。
渲染一律用 --demo-official 示範資料（SnapshotPrivacy），不放任何真實個人資料。
"""
import subprocess, sys, json, shutil
from pathlib import Path
from PIL import Image

SRC = Path(sys.argv[1])
OUT = Path(__file__).resolve().parent.parent / 'public' / 'media' / '2.0'
# 螢幕平面圖（1024² 畫布的放大版）：頁面最寬顯示約 600 CSS px
SCREENS = ['home-light', 'home-dark', 'home-clear', 'home-tinted', 'widget-gallery', 'home-edit', 'home-library',
           'la-compact', 'la-expanded', 'cc',
           *[f'face-{s}' for s in ['island', 'photos', 'modular', 'analog', 'flow', 'weather', 'world', 'calendar', 'growth', 'black', 'system6', 'cluster']],
           'app-weather-rain', 'app-timers', 'app-music', 'app-messages-confirm', 'app-facetime', 'app-home', 'app-recipe-step',
           'app-intercom', 'clio-listen', 'clio-answer', 'clio-confirm', 'people-greet']
SCREEN_W = [480, 960]
PROD = ['prod-island', 'prod-home']
PROD_BOX = (350, 80, 1450, 1360)   # 1100×1280：機身外留一點影子
PROD_W = [640, 1100]

def run(*a):
    subprocess.run(a, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def encode(im, base, widths, q_avif=58, q_webp=80, alpha=False):
    for w in widths:
        h = round(im.height * w / im.width)
        tmp = base.parent / f'.{base.name}-{w}.png'
        im.resize((w, h), Image.LANCZOS).save(tmp)
        run('avifenc', '-q', str(q_avif), '-s', '4', '-y', '420' if not alpha else '444', tmp, f'{base}-{w}.avif')
        run('cwebp', '-q', str(q_webp), '-m', '6', *(['-exact', '-alpha_q', '90'] if alpha else []), tmp, '-o', f'{base}-{w}.webp')
        tmp.unlink()

sizes = {}
for lang_dir in (SRC / l for l in ('zh-Hant', 'zh-Hans', 'en')):
    lang = lang_dir.name
    out = OUT / lang; out.mkdir(parents=True, exist_ok=True)
    for n in SCREENS:
        f = lang_dir / f'{n}.png'
        if not f.exists(): print('missing', f); continue
        im = Image.open(f).convert('RGB')
        encode(im, out / n, SCREEN_W)
    for n in PROD:
        f = lang_dir / f'{n}.png'
        if not f.exists(): print('missing', f); continue
        im = Image.open(f).convert('RGBA').crop(PROD_BOX)
        encode(im, out / n, PROD_W, q_avif=62, alpha=True)
        sizes['prod'] = list(im.size)
print(json.dumps(sizes))
