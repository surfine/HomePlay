#!/usr/bin/env python3
"""HomeView 網格疊圖（docs/plans/grid.md 合約的方法第 2 點）。

用法：python3 tooling/grid-overlay.py in.png out.png [--home|--app] [--label]
  --home  強調主畫面網格（98.5／925.5、欄距 225 的四欄邊界與圖示框）
  --app   強調 App 內容線（64／960）——預設
  --label 在頂端標出每條豎線的 x 值（稽核時對讀座標用）

只依賴 Pillow；PNG 進、PNG 出。畫布 1024 × 1024（HPGrid.canvas）。
"""
import argparse
import sys

from PIL import Image, ImageDraw

CANVAS = 1024
MID = 512.0

# HPGrid.swift 的常數（只讀鏡射；數值改動先問使用者）
HOME_MARGIN = 98.5      # HPGrid.Home.margin
HOME_PITCH = 225.0      # HPGrid.Home.columnPitch
HOME_ICON = 152.0       # HPGrid.Home.iconSide
APP_LEADING = 64.0      # HPGrid.App.leading
APP_TRAILING = 960.0    # HPGrid.App.trailing
PANEL_MARGIN = 24.0     # HPGrid.Panel.margin
SCALE_STEP = 8.0        # 8 px 淡格線

# 顏色（半透明，畫在原圖上）
FAINT = (255, 255, 255, 26)        # 8 px 淡格線
KEY = (255, 60, 60, 150)           # 64／960 與 24／1000
MID_C = (60, 200, 255, 170)        # 512 中線
HOME = (60, 255, 140, 170)         # 98.5／925.5 與欄界
LABEL = (255, 255, 255, 230)
LABEL_BG = (0, 0, 0, 160)


def overlay(src: Image.Image, mode: str, label: bool) -> Image.Image:
    img = src.convert("RGBA")
    ov = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    w, h = img.size

    # 8 px 淡格線（整張畫布）
    x = SCALE_STEP
    while x < w:
        d.line([(x, 0), (x, h)], fill=FAINT, width=1)
        x += SCALE_STEP
    y = SCALE_STEP
    while y < h:
        d.line([(0, y), (w, y)], fill=FAINT, width=1)
        y += SCALE_STEP

    # 滿版面板外緣 24／1000（横竖都畫；竖線只在上下端畫短一點避免太吵——照合約全文畫整條）
    for v in (PANEL_MARGIN, w - PANEL_MARGIN):
        d.line([(v, 0), (v, h)], fill=KEY, width=1)
    for v in (PANEL_MARGIN, h - PANEL_MARGIN):
        d.line([(0, v), (w, v)], fill=KEY, width=1)

    # App 對齊線 64／960
    for v in (APP_LEADING, APP_TRAILING):
        d.line([(v, 0), (v, h)], fill=KEY, width=2)

    # 中線 512
    d.line([(MID, 0), (MID, h)], fill=MID_C, width=1)
    d.line([(0, MID), (w, MID)], fill=MID_C, width=1)

    marks = {str(int(APP_LEADING)): APP_LEADING, str(int(APP_TRAILING)): APP_TRAILING,
             "24": PANEL_MARGIN, "1000": w - PANEL_MARGIN, "512": MID}

    # 主畫面網格
    if mode == "home":
        for v in (HOME_MARGIN, w - HOME_MARGIN):
            d.line([(v, 0), (v, h)], fill=HOME, width=2)
        marks[str(HOME_MARGIN)] = HOME_MARGIN
        marks[str(w - HOME_MARGIN)] = w - HOME_MARGIN
        for k in range(4):
            x0 = HOME_MARGIN + k * HOME_PITCH
            # 欄的圖示框（152 × 152），顶边随内容不畫，只畫左右界與中心線
            d.line([(x0, 0), (x0, h)], fill=HOME, width=1)
            d.line([(x0 + HOME_ICON, 0), (x0 + HOME_ICON, h)], fill=HOME, width=1)
            cx = x0 + HOME_ICON / 2
            d.line([(cx, 0), (cx, h)], fill=(60, 255, 140, 80), width=1)
            marks[f"c{k + 1}"] = cx

    img.alpha_composite(ov)

    if label:
        d2 = ImageDraw.Draw(img)
        y = 4
        for name, v in sorted(marks.items(), key=lambda kv: kv[1]):
            text = name
            tw = d2.textlength(text)
            d2.rectangle([v - 2, y - 2, v + tw + 4, y + 14], fill=LABEL_BG)
            d2.text((v, y), text, fill=LABEL)
    return img


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input")
    ap.add_argument("output")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--home", action="store_true", help="強調主畫面網格（98.5／925.5、四欄）")
    g.add_argument("--app", action="store_true", help="強調 App 內容線（64／960；預設）")
    ap.add_argument("--label", action="store_true", help="頂端標出每條豎線的 x 值")
    a = ap.parse_args()
    mode = "home" if a.home else "app"
    src = Image.open(a.input)
    if src.size != (CANVAS, CANVAS):
        print(f"warning: 輸入不是 1024×1024（{src.size}），線照 1024 畫布的位置畫", file=sys.stderr)
    overlay(src, mode, a.label).convert("RGB").save(a.output, "PNG")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
