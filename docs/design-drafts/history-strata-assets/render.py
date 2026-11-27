"""Procedural renders of the machine shells for history-strata.html.

Every shell is built from measured geometry (units: percent of case width,
the same numbers the page's CSS uses) as a height field, then lit:
key light from the upper left (Infinite Mac's convention), soft fill, Blinn
specular, cavity occlusion and a little plastic grain.  The screen opening
is left transparent so the live DOM screen shows through.
No pixels are taken from any reference image; references were only measured.
"""
import sys
import numpy as np
from PIL import Image

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
import os
PX = float(os.environ.get("SHELL_PX", "20"))  # pixels per unit (case width 100 units -> 2000 px)


# ---------- geometry helpers ----------
def grid(w_units, h_units):
    w, h = int(round(w_units * PX)), int(round(h_units * PX))
    y, x = np.mgrid[0:h, 0:w].astype(np.float64)
    return (x + 0.5) / PX, (y + 0.5) / PX


def rrect(X, Y, x0, y0, x1, y1, r):
    cx, cy, hx, hy = (x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2, (y1 - y0) / 2
    qx, qy = np.abs(X - cx) - hx + r, np.abs(Y - cy) - hy + r
    out = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0))
    ins = np.minimum(np.maximum(qx, qy), 0)
    return out + ins - r


def circle(X, Y, cx, cy, r):
    return np.hypot(X - cx, Y - cy) - r


def ellipse(X, Y, cx, cy, rx, ry):
    return (np.hypot((X - cx) / rx, (Y - cy) / ry) - 1) * min(rx, ry)


def cover(d):
    """Anti-aliased coverage of the inside (d<0)."""
    return np.clip(0.5 - d * PX, 0, 1)


def rounded(d, b):
    """Quarter-round edge: 0 at the outline, 1 once b units inside."""
    t = np.clip(-d / b, 0, 1)
    return np.sqrt(1 - (1 - t) ** 2)


def ramp(d, b):
    t = np.clip(-d / b, 0, 1)
    return t * t * (3 - 2 * t)


def blur(a, r_units):
    r = max(1, int(r_units * PX))
    out = a
    for _ in range(3):  # three box passes ~ gaussian
        for ax in (0, 1):
            c = np.cumsum(np.pad(out, [(r + 1, r) if i == ax else (0, 0) for i in range(2)], mode="edge"), axis=ax)
            if ax == 0:
                out = (c[2 * r + 1:] - c[:-2 * r - 1]) / (2 * r + 1)
            else:
                out = (c[:, 2 * r + 1:] - c[:, :-2 * r - 1]) / (2 * r + 1)
    return out


# ---------- shading ----------
L = np.array([-0.2, -0.7, 0.66]); L /= np.linalg.norm(L)   # fitted to the icon's luminance (RMS 8.7 / 255)
V = np.array([0.0, 0.0, 1.0])
Hv = (L + V) / np.linalg.norm(L + V)


UP = np.array([0.0, -0.55, 0.835]); UP /= np.linalg.norm(UP)


def cast_shadow(h, reach=4.0, steps=24, soft=1.5):
    """Screen-space shadows from the height field along the key light's direction."""
    lxy = np.array([L[0], L[1]]); lxy_n = lxy / np.linalg.norm(lxy)
    rise = L[2] / np.linalg.norm(lxy)            # height gained per unit travelled toward the light
    sh = np.zeros_like(h)
    for i in range(1, steps + 1):
        t = reach * i / steps
        dx, dy = int(round(lxy_n[0] * t * PX)), int(round(lxy_n[1] * t * PX))
        shifted = np.zeros_like(h)                                      # shift without wrapping: outside is empty
        H_, W_ = h.shape
        ys, yd = (slice(max(dy, 0), H_ + min(dy, 0)), slice(max(-dy, 0), H_ + min(-dy, 0)))
        xs, xd = (slice(max(dx, 0), W_ + min(dx, 0)), slice(max(-dx, 0), W_ + min(-dx, 0)))
        shifted[yd, xd] = h[ys, xs]
        sh = np.maximum(sh, np.clip((shifted - h - rise * t) * soft, 0, 1))
    return 1 - 0.85 * blur(sh, 0.15)


def shade(h, albedo, *, relief=1.0, amb=None, kd=0.62, ks=0.10, shin=28.0,
          ao=0.9, ao_r=1.2, grain=1.0, sky=None, seed=1, macro=None,
          sky_c=1.0, ground_c=0.40, amb_w=0.58, shadows=True, falloff=0.0, softbox=0.0, fall_exp=6):
    """Hemisphere ambient (sky above, ground below) + key light with cast shadows
    + two-scale cavity occlusion + Blinn specular with a Fresnel lift.
    h: height in units (detail). macro: an extra smooth shape that only bends the normals
    (the broad curvature of a moulded front). Returns float RGB in 0..255."""
    hn = h * relief + (macro if macro is not None else 0)
    gy, gx = np.gradient(hn, 1 / PX)
    n = np.dstack([-gx, -gy, np.ones_like(h)])
    n /= np.linalg.norm(n, axis=2, keepdims=True)
    hemi = np.clip(0.5 + 0.5 * (n @ UP), 0, 1)
    ambient = ground_c + (sky_c - ground_c) * hemi
    lam = np.clip(n @ L, 0, None)
    if shadows:
        lam = lam * cast_shadow(h * relief)
    nz = np.clip(n[..., 2], 0, 1)
    spec = np.clip(n @ Hv, 0, None) ** shin * (1 + 2.5 * (1 - nz) ** 3)
    cav = np.clip(blur(h, ao_r) - h, 0, None) * ao + np.clip(blur(h, ao_r * 4) - h, 0, None) * ao * 0.35
    occ = 1 - np.clip(cav, 0, 0.6)
    if macro is not None and falloff:
        my, mx = np.gradient(macro, 1 / PX)
        mz = 1 / np.sqrt(1 + mx ** 2 + my ** 2)                        # only the broad curvature falls off
        fall = 1 - falloff * (1 - mz ** fall_exp)
    else:
        fall = 1.0
    light = (amb_w * ambient + kd * lam) * occ * fall
    if softbox:                                                       # a soft light above: higher parts read brighter
        Hh = h.shape[0]
        light = light * (1 + softbox * (0.5 - np.arange(Hh)[:, None] / Hh))
    alb = np.asarray(albedo, float)[None, None, :]
    rgb = alb * light[..., None]
    # shadows run slightly warmer and more saturated, as moulded plastic does
    warm = np.clip(1 - light, 0, 1)[..., None] * np.array([0.0, -0.025, -0.07])
    rgb = rgb * (1 + warm) + 255 * ks * spec[..., None]
    if grain:
        rng = np.random.default_rng(seed)
        rgb += rng.normal(0, grain, h.shape)[..., None]
    return rgb


def bulge(X, Y, cx, cy, rx, ry, depth):
    """Broad convex curvature of a moulded front, as a normals-only height field."""
    return depth * (np.clip(1 - ((X - cx) / rx) ** 2, 0, 1) + 0.5 * np.clip(1 - ((Y - cy) / ry) ** 2, 0, 1))


def save(rgb, alpha, name):
    a = np.clip(alpha, 0, 1)
    img = np.dstack([np.clip(rgb, 0, 255), a * 255]).astype(np.uint8)
    im = Image.fromarray(img, "RGBA")
    im.save(f"{OUT}/{name}.webp", "WEBP", quality=88, method=6)
    im.resize((im.width // 4, im.height // 4), Image.LANCZOS).save(f"{OUT}/{name}-preview.png")
    print(name, im.size)


# ---------- Macintosh 128K (100 x 130.9) ----------
# Positions measured on Frame of preference's front render (case width = 100, from the top of the case):
# top surface 0-8.3, square recess x 8.8-91.2 / y 14.5-75.8, tube glass x 11.8-88.2 / y 16.1-73.0 (4:3),
# floppy slot x 50.8-87.9 at y 93.1, lower band 116.7-130.9 with the keyboard jack at x 84-90.4.
def mac128():
    X, Y = grid(100, 130.9)
    case = rrect(X, Y, 0, 0, 100, 130.9, 2.2)
    h = 3.0 * rounded(rrect(X, Y, 0, 0, 100, 140, 2.2), 1.4)            # no bevel along the bottom
    h += 0.25 * np.clip((8.3 - Y) / 0.4, 0, 1)                                # top surface catches the light
    recess = rrect(X, Y, 8.8, 14.5, 91.2, 75.8, 1.2)
    glass = rrect(X, Y, 11.8, 16.1, 88.2, 73.0, 3.0)
    h -= 0.7 * ramp(recess, 2.6)                                             # square frame: a wide, shallow slope into the tube
    slot = rrect(X, Y, 50.8, 92.05, 87.9, 94.15, 0.8)
    plate = rrect(X, Y, 79.5, 91.0, 89.6, 95.2, 0.6)                        # the slot's thicker eject end
    h += 0.18 * ramp(plate, 0.3) - 1.2 * ramp(slot, 0.3)
    h -= 0.5 * np.exp(-((Y - 116.7) / 0.25) ** 2)                            # break above the lower band
    h -= 0.25 * np.clip((Y - 116.7) / 0.6, 0, 1) * (Y > 116.7)              # band sits slightly back
    jack = rrect(X, Y, 84.0, 119.4, 90.4, 126.4, 0.5)
    h -= 0.35 * ramp(jack, 0.25)
    rgb = shade(h, (236, 222, 207), relief=1.0, ks=0.05, shin=20, ao=0.35, grain=1.2,
                macro=4.0 * np.clip(1 - ((X - 50) / 52) ** 2, 0, 1), fall_exp=10, falloff=0.5,
                amb_w=0.86, kd=0.24, softbox=0.05, shadows=False)
    rgb = np.where((Y < 8.3)[..., None], rgb * 1.05, rgb)
    rgb = np.where((slot < 0)[..., None], rgb * 0.12 + 6, rgb)
    hole = rrect(X, Y, 85.4, 121.0, 88.8, 124.9, 0.3) < 0
    rgb = np.where(hole[..., None], np.array([30, 28, 26]), rgb)
    alpha = cover(case) * (1 - cover(glass))
    save(rgb, alpha, "mac128")


CRT_P = dict(depth=7.0, rx=52, exp=10, fall=0.8, amb=0.80, kd=0.34)


# ---------- Beige CRT (100 x 89.7) + stand (50.7 x 12) ----------
def crt():
    X, Y = grid(100, 89.7)
    arc = 2.0 * ((X - 50) / 50) ** 2          # top edge bows up in the middle
    case = np.maximum(rrect(X, Y, 0, 0, 100, 89.7, 2.0), arc - Y)
    h = 2.6 * rounded(np.maximum(rrect(X, Y, 0, 0, 100, 96, 2.0), arc - Y), 0.9)   # no bevel along the bottom
    glass = rrect(X, Y, 7.7, 9.0, 92.3, 72.7, 1.4)
    lipr = rrect(X, Y, 6.3, 7.6, 93.7, 74.4, 2.4)
    h -= 1.0 * ramp(lipr, 1.5)                # sloped lip into the tube
    # chin buttons: each sits in a recessed well; the lower wall of the well catches the light
    def well(cx, cy, r_out, r_face, depth, dome):
        rr = np.hypot(X - cx, Y - cy)
        wall = np.clip((r_out - rr) / (r_out - r_face), 0, 1)
        face = np.sqrt(np.clip(1 - (rr / r_face) ** 2, 0, 1))
        return -depth * wall + dome * face * (rr < r_face)
    centres = [41.45 + 5.6 * i for i in range(4)]
    for cx in centres:
        h += well(cx, 83.0, 2.55, 2.05, 0.55, 0.45)
    h += well(70.35, 83.0, 3.6, 3.0, 0.6, 0.5)
    h += well(64.55, 83.0, 1.05, 0.65, 0.6, 0.0)
    rgb = shade(h, (232, 226, 186), relief=1.0, ks=0.06, shin=18, ao=1.0, grain=1.0, seed=2,
                macro=CRT_P['depth'] * np.clip(1 - ((X - 50) / CRT_P['rx']) ** 2, 0, 1),
                fall_exp=CRT_P['exp'], falloff=CRT_P['fall'], amb_w=CRT_P['amb'], kd=CRT_P['kd'], softbox=0.20)
    faces = np.zeros_like(X, bool)
    for cx in centres:
        faces |= np.hypot(X - cx, Y - 83.0) < 1.95
    faces |= np.hypot(X - 70.35, Y - 83.0) < 2.9
    rgb = np.where(faces[..., None], rgb * 1.13 + 6, rgb)                   # pale caps
    for cx in centres:                                                       # small dash on each face
        g = (np.abs(Y - 83.0) < 0.09) & (np.abs(X - cx) < 0.22)
        rgb = np.where(g[..., None], rgb * 0.55, rgb)
    rr = np.hypot(X - 70.35, Y - 83.0)                                       # power glyph
    gl = (np.abs(rr - 0.85) < 0.1) & ~((Y < 82.6) & (np.abs(X - 70.35) < 0.5))
    gl |= (np.abs(X - 70.35) < 0.1) & (Y > 81.85) & (Y < 83.05)
    rgb = np.where(gl[..., None], rgb * 0.55, rgb)
    rl = np.hypot(X - 64.55, Y - 83.0)                                       # orange LED in its socket
    led = rl < 0.62
    glow = np.exp(-(rl / 1.2) ** 2)
    rgb = rgb + np.array([70, 35, 0]) * glow[..., None] * (rl > 0.62)[..., None]
    core = np.array([255, 178, 40]) * (1 - 0.25 * np.clip(rl / 0.62, 0, 1))[..., None] + 105 * np.exp(-((X - 64.4) ** 2 + (Y - 82.8) ** 2) / 0.05)[..., None]
    rgb = np.where(led[..., None], core, rgb)
    alpha = cover(case) * (1 - cover(glass))
    save(rgb, alpha, "crt")

    # stand, after the icon's outline (stand units: x 0..50.7 over the case's x 24.65..75.35, y 0..12 below the case)
    X, Y = grid(50.7, 12)
    c = 25.35
    dx = X - c
    # 1) swivel bowl: flat top under the case, elliptical underside
    bowl = ellipse(X, Y, c, -0.2, 24.2, 3.6)
    hb = 2.2 * np.sqrt(np.clip(1 - (dx / 24.2) ** 2 - ((Y + 0.2) / 3.6) ** 2, 0, 1))
    # 2) rear legs, mostly hidden, in shadow
    rear = rrect(X, Y, 3.6, 2.6, 47.1, 6.2, 1.2)
    # 3) front foot: top edge dips in the middle, legs flare to the front corners
    top_edge = 3.7 + 2.9 * np.clip(1 - (dx / 21.0) ** 2, 0, 1)
    t = np.clip((Y - 5.0) / 6.5, 0, 1)
    hw = 21.2 + 4.1 * t ** 1.6                                            # legs flare smoothly toward the front corners
    foot = np.maximum(np.maximum(top_edge - Y, Y - 11.7), np.abs(dx) - hw)
    hf = 1.4 * rounded(foot, 1.1) + 0.9 * (dx / 22.0) ** 2 - 0.5 * np.clip((Y - 8.0) / 3.7, 0, 1)
    h = np.where(bowl < 0, hb + 1.0, np.where(foot < 0, hf, np.where(rear < 0, 0.3 * rounded(rear, 0.6), 0.0)))
    rgb = shade(h, (216, 210, 172), ks=0.08, shin=18, ao=0.9, grain=0.9, seed=3)
    rim = (bowl < 0) & (bowl > -0.55) & (Y > 0.8)                          # dark crescent under the bowl
    rgb = np.where(rim[..., None], rgb * 0.62, rgb)
    rgb = np.where(((rear < 0) & (bowl >= 0) & (foot >= 0))[..., None], rgb * 0.8, rgb)
    rgb = np.where(((Y < 0.9) & (bowl < 0))[..., None], rgb * (0.55 + 0.45 * (Y / 0.9))[..., None], rgb)  # case shadow
    alpha = np.maximum(np.maximum(cover(bowl), cover(foot)), cover(rear))
    save(rgb, alpha, "crt-stand")


# ---------- iBook G4 12" lid (100 x 75.3) + base (104 x 4.2) ----------
def ibook():
    X, Y = grid(100, 75.3)
    lid = rrect(X, Y, 0, 0, 100, 75.3, 1.8)
    h = 0.55 * rounded(lid, 0.35)                                            # crisp outer edge
    h -= 0.10 * np.exp(-((lid + 0.75) / 0.07) ** 2)                          # fine groove: the rim around the lid
    op = rrect(X, Y, 4.85, 4.8, 95.15, 72.7, 0.25)
    slot = rrect(X, Y, 47.3, 1.1, 52.7, 1.65, 0.27)
    h -= 0.6 * ramp(slot, 0.12)                                              # latch slot
    for cx in (2.3, 97.7):                                                   # flat rubber bumpers
        h += 0.08 * ramp(circle(X, Y, cx, 2.6, 0.62), 0.12)
    rgb = shade(h, (236, 236, 236), ks=0.06, shin=30, ao=0.8, grain=0.5, seed=4, amb_w=0.84, kd=0.30, softbox=0.06)
    rgb *= (1.03 - 0.05 * (Y / 75.3))[..., None]
    rgb = np.where((slot < 0)[..., None], np.array([28, 28, 28]), rgb)
    for cx in (2.3, 97.7):
        b_ = circle(X, Y, cx, 2.6, 0.62) < 0
        rgb = np.where(b_[..., None], rgb * 0.93, rgb)
    hole = circle(X, Y, 97.45, 21.8, 0.3)
    halo = (hole < 0.14) & (hole >= 0) & (Y > 21.8)
    rgb = np.where(halo[..., None], np.minimum(rgb + 25, 255), rgb)
    rgb = np.where((hole < 0)[..., None], np.array([22, 22, 22]), rgb)
    alpha = cover(lid) * (1 - cover(op))
    save(rgb, alpha, "ibook")

    X, Y = grid(104, 7.5)
    base = rrect(X, Y, 0, -3, 104, 7.5, 1.8)
    deck = Y < 2.2
    h = np.where(deck, 0.6 + 0.2 * Y / 2.2, 1.0 * rounded(base, 1.4) + 0.4 * np.sqrt(np.clip(1 - ((Y - 4.9) / 2.8) ** 2, 0, 1)))
    rgb = shade(h, (242, 242, 242), ks=0.12, shin=36, ao=0.9, grain=0.5, seed=5, amb_w=0.84, kd=0.30)
    rgb = np.where(deck[..., None], rgb * (0.80 + 0.12 * Y / 2.2)[..., None], rgb)         # hinge shadow on the deck
    keys = deck & (Y > 0.8) & (Y < 1.5) & (np.mod(X - 9.0, 4.3) < 3.8) & (X > 9) & (X < 95)
    rgb = np.where(keys[..., None], rgb * 0.94, rgb)
    pad = deck & (Y > 1.5) & (np.abs(X - 52) < 9.5)
    rgb = np.where(pad[..., None], rgb * 0.96, rgb)
    rgb = np.where((np.abs(Y - 2.2) < 0.07)[..., None], rgb * 0.82, rgb)
    btn = rrect(X, Y, 44.8, 4.25, 59.2, 5.35, 0.55)
    ring = rrect(X, Y, 44.5, 3.95, 59.5, 5.65, 0.85)
    rgb = np.where(((ring < 0) & (btn >= 0))[..., None], np.array([196, 198, 202]), rgb)
    rgb = np.where((btn < 0)[..., None], np.array([40, 41, 44]) + 110 * np.exp(-((Y - 4.55) / 0.22) ** 2)[..., None], rgb)
    alpha = cover(base) * (Y > 0)
    save(rgb, alpha, "ibook-base")


# ---------- black LCD (100 x 76.55) + oval foot (33.3 x 3.5) ----------
def lcd():
    X, Y = grid(100, 76.55)
    case = rrect(X, Y, 0, 0, 100, 76.55, 1.1)
    h = 0.9 * rounded(case, 0.7)
    op = rrect(X, Y, 3.1, 3.1, 96.9, 73.45, 0.1)
    h -= 0.25 * ramp(rrect(X, Y, 2.9, 2.9, 97.1, 73.65, 0.3), 0.2)
    rgb = shade(h, (17, 17, 17), ks=0.22, shin=60, ao=0.6, grain=0.5, amb=0.9, kd=0.4, seed=6)
    rgb[: int(0.12 * PX)] += 30                                             # bright top edge
    alpha = cover(case) * (1 - cover(op))
    save(rgb, alpha, "lcd")

    # foot: the lower half of a dark metal lens; its top edge sits flat under the display,
    # a bright reflection runs along the lower arc (after the icon)
    X, Y = grid(33.3, 3.5)
    e = ellipse(X, Y, 16.65, 0.0, 16.5, 3.1)
    t = np.clip(Y / 3.1, 0, 1)
    base = np.array([34, 34, 36]) + (t ** 1.6)[..., None] * np.array([120, 121, 124])
    band = np.exp(-((e + 0.32) / 0.12) ** 2)                                 # bright rim just inside the arc
    inner = 0.35 * np.exp(-((e + 1.05) / 0.35) ** 2)                         # soft second reflection
    rgb = base + (band + inner)[..., None] * np.array([200, 200, 204])
    rgb *= (1 - 0.55 * np.exp(-(Y / 0.45) ** 2))[..., None]                  # shadow from the display above
    save(rgb, cover(e) * (Y > 0), "lcd-foot")


if __name__ == "__main__":
    for f in sys.argv[2:] or ["mac128", "crt", "ibook", "lcd"]:
        globals()[f]()
