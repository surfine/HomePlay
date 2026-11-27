"""Crop a render to its visible extent (alpha > 0, shadow included) and print the CSS placement
of that image relative to the page box, in page units (case width = 100 = 100cqw)."""
import json, sys
from PIL import Image
import numpy as np

out = sys.argv[1]
for name in sys.argv[2:]:
    im = Image.open(f"{out}/{name}-full.png").convert("RGBA")
    box = json.load(open(f"{out}/{name}-boxes.json"))["page"]
    (x0, y0), (x1, y1) = box
    a = np.asarray(im)[..., 3]
    ys, xs = np.where(a > 24)
    bx0, by0, bx1, by1 = xs.min(), ys.min(), xs.max() + 1, ys.max() + 1
    k = 100 / (x1 - x0)                                   # page units per pixel
    c = im.crop((bx0, by0, bx1, by1))
    c.save(f"{out}/{name}3d.webp", "WEBP", quality=90, method=6)
    css = dict(left=round((bx0 - x0) * k, 3), top=round((by0 - y0) * k, 3),
               width=round((bx1 - bx0) * k, 3), height=round((by1 - by0) * k, 3),
               below=round((by1 - y1) * k, 3))
    print(name, c.size, json.dumps(css))
