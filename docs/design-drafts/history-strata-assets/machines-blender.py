"""Mac 128K, iBook G4 12" and black LCD for history-strata.html, modelled from measured proportions
and rendered in Cycles with the same studio light as the CRT (crt.py).

Units: case width = 1.0 m (= 100 page units). Front face at y = 0, facing -Y; the case's bottom at z = 0.
Each render writes <name>-full.png plus <name>-boxes.json giving where the page box lands in pixels.
Run: blender -b --factory-startup --python machines.py -- OUTDIR NAME [samples]
"""
import bpy, math, sys, json, os
from mathutils import Vector
from bpy_extras.object_utils import world_to_camera_view

argv = sys.argv[sys.argv.index("--") + 1:]
OUT, NAME = argv[0], argv[1]
SAMPLES = int(argv[2]) if len(argv) > 2 else 128
U = 0.01

bpy.ops.wm.read_factory_settings(use_empty=True)
scn = bpy.context.scene


def srgb(c):
    c = c / 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def mat(name, rgb, rough=0.45, spec=0.5, coat=0.0, metal=0.0, grain=0.04, emit=None, sss=0.04):
    m = bpy.data.materials.new(name); m.use_nodes = True
    nt = m.node_tree; b = nt.nodes["Principled BSDF"]
    base = (*[srgb(x) for x in rgb], 1)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Specular IOR Level"].default_value = spec
    b.inputs["Coat Weight"].default_value = coat
    b.inputs["Metallic"].default_value = metal
    b.inputs["Subsurface Weight"].default_value = sss
    b.inputs["Subsurface Radius"].default_value = (0.004, 0.003, 0.002)
    # faint, large-scale colour variation: real moulded plastic is never one flat colour
    var = nt.nodes.new("ShaderNodeTexNoise"); var.inputs["Scale"].default_value = 6; var.inputs["Detail"].default_value = 3
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    lo = tuple(c * 0.965 for c in base[:3]) + (1,); hi = tuple(min(1, c * 1.02) for c in base[:3]) + (1,)
    ramp.color_ramp.elements[0].color = lo; ramp.color_ramp.elements[1].color = hi
    nt.links.new(var.outputs["Fac"], ramp.inputs["Fac"]); nt.links.new(ramp.outputs["Color"], b.inputs["Base Color"])
    if metal: b.inputs["Base Color"].default_value = base
    if emit:
        b.inputs["Emission Color"].default_value = (*emit, 1); b.inputs["Emission Strength"].default_value = 5
    if grain:
        tex = nt.nodes.new("ShaderNodeTexNoise"); tex.inputs["Scale"].default_value = 900; tex.inputs["Detail"].default_value = 2
        bump = nt.nodes.new("ShaderNodeBump"); bump.inputs["Strength"].default_value = grain; bump.inputs["Distance"].default_value = 0.0004
        nt.links.new(tex.outputs["Fac"], bump.inputs["Height"]); nt.links.new(bump.outputs["Normal"], b.inputs["Normal"])
    return m


def holdout_mat():
    m = bpy.data.materials.new("holdout"); m.use_nodes = True
    nt = m.node_tree; nt.nodes.clear()
    o = nt.nodes.new("ShaderNodeOutputMaterial"); h = nt.nodes.new("ShaderNodeHoldout")
    nt.links.new(h.outputs[0], o.inputs["Surface"]); return m


def box(name, x0, x1, z0, z1, y0, y1, bevel=0.0, seg=6, m=None):
    bpy.ops.mesh.primitive_cube_add(size=1, location=((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2))
    o = bpy.context.object; o.name = name; o.scale = (x1 - x0, y1 - y0, z1 - z0)
    bpy.ops.object.transform_apply(scale=True)
    if bevel:
        b = o.modifiers.new("bevel", "BEVEL"); b.width = bevel; b.segments = seg; b.limit_method = "ANGLE"
    if m: o.data.materials.append(m)
    return o


def cyl(name, x, z, r, y0, y1, bevel=0.0, m=None, verts=64):
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=r, depth=y1 - y0, location=(x, (y0 + y1) / 2, z), rotation=(math.pi / 2, 0, 0))
    o = bpy.context.object; o.name = name
    if bevel:
        b = o.modifiers.new("bevel", "BEVEL"); b.width = bevel; b.segments = 6; b.limit_method = "ANGLE"
    if m: o.data.materials.append(m)
    return o


def apply_mods(o):
    bpy.context.view_layer.objects.active = o
    for md in list(o.modifiers):
        bpy.ops.object.modifier_apply(modifier=md.name)


def cut(target, cutter, keep_mat=None):
    apply_mods(cutter)
    if keep_mat:                      # faces made by this cut take the cutter's material
        cutter.data.materials.append(keep_mat)
        target.data.materials.append(keep_mat)
    md = target.modifiers.new("cut", "BOOLEAN"); md.operation = "DIFFERENCE"; md.object = cutter; md.solver = "EXACT"
    md.material_mode = "TRANSFER" if keep_mat else "INDEX"
    apply_mods(target)
    bpy.data.objects.remove(cutter, do_unlink=True)


def holdout(x0, x1, z0, z1, y):
    o = box("holdout", x0, x1, z0, z1, y, y + 0.004); o.data.materials.append(holdout_mat()); return o


def studio(world=0.32, key=260, fill=40, top=130, center_z=0.4):
    def area(name, loc, size, power):
        bpy.ops.object.light_add(type="AREA", location=loc)
        l = bpy.context.object; l.name = name; l.data.size = size; l.data.energy = power
        d = Vector((0.5, 0.2, center_z)) - Vector(loc); l.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    area("key", (-1.2, -2.6, 2.6), 2.2, key)
    area("fill", (2.4, -2.4, 0.9), 2.0, fill)
    area("top", (0.5, -0.6, 3.2), 3.0, top)
    w = bpy.data.worlds.new("w"); scn.world = w; w.use_nodes = True
    nt = w.node_tree; bg = nt.nodes["Background"]
    tc = nt.nodes.new("ShaderNodeTexCoord"); sep = nt.nodes.new("ShaderNodeSeparateXYZ"); rp = nt.nodes.new("ShaderNodeValToRGB")
    rp.color_ramp.elements[0].position = 0.35; rp.color_ramp.elements[0].color = (world * 0.35, world * 0.35, world * 0.36, 1)   # floor side: darker
    rp.color_ramp.elements[1].position = 0.75; rp.color_ramp.elements[1].color = (world * 1.6, world * 1.6, world * 1.62, 1)   # ceiling side: a bright studio
    mr = nt.nodes.new("ShaderNodeMapRange"); mr.inputs["From Min"].default_value = -1; mr.inputs["From Max"].default_value = 1
    nt.links.new(tc.outputs["Generated"], sep.inputs[0]) if False else nt.links.new(tc.outputs["Normal"], sep.inputs[0])
    nt.links.new(sep.outputs["Z"], mr.inputs["Value"]); nt.links.new(mr.outputs["Result"], rp.inputs["Fac"]); nt.links.new(rp.outputs["Color"], bg.inputs["Color"])


def floor(z):
    bpy.ops.mesh.primitive_plane_add(size=8, location=(0.5, 0.5, z))
    bpy.context.object.is_shadow_catcher = True


def camera(top_z, bottom_z, res_x=2320, res_y=2320, frame_w=1.2, center_dz=0.0, screen_cz=None, real_w=0.30):
    """The shared museum camera: a level perspective camera with a shift lens (no keystone, so the
    front face and its screen stay a true rectangle), 100 mm on 36 mm, eye 8 degrees above the
    centre of the screen, like a seated viewer. Every machine is photographed the same way."""
    sensor = 36.0
    D = 1.5 / real_w                                # every machine is photographed from 1.5 m in real life (scene width 1 = real_w metres)
    lens = D * sensor / frame_w                     # focal length only crops (frame_w wide at the front plane)
    eye = screen_cz + D * math.tan(math.radians(float(os.environ.get("ELEV", "8"))))
    bpy.ops.object.camera_add(); cam = bpy.context.object; scn.camera = cam
    cam.data.type = "PERSP"; cam.data.lens = lens; cam.data.sensor_width = sensor; cam.data.sensor_fit = "HORIZONTAL"
    cam.location = (0.5, -D, eye); cam.rotation_euler = (math.pi / 2, 0, 0)
    cz = (top_z + bottom_z) / 2 + center_dz
    cam.data.shift_y = (cz - eye) / frame_w
    cam.data.clip_end = 100
    R = scn.render
    R.engine = "CYCLES"; scn.cycles.device = "GPU"; scn.cycles.samples = SAMPLES; scn.cycles.use_denoising = True
    p = bpy.context.preferences.addons["cycles"].preferences; p.compute_device_type = "METAL"; p.get_devices()
    for d in p.devices: d.use = True
    R.film_transparent = True; R.resolution_x = res_x; R.resolution_y = res_y
    R.resolution_percentage = int(os.environ.get("PCT", "100"))
    scn.view_settings.view_transform = "Standard"; scn.view_settings.exposure = float(os.environ.get("EXPO", "-1.5"))
    R.image_settings.file_format = "PNG"; R.image_settings.color_mode = "RGBA"
    R.filepath = os.path.join(OUT, f"{NAME}-full.png")
    return cam


def finish(cam, page_box, glass_box=None, quad=None):
    """page_box: (x0, z_top, x1, z_bottom) of the page element on the front plane."""
    bpy.context.view_layer.update()
    R = scn.render
    def px(x, z):
        co = world_to_camera_view(scn, cam, Vector((x, 0.0, z)))
        return [co.x * R.resolution_x, (1 - co.y) * R.resolution_y]
    x0, zt, x1, zb = page_box
    out = {"page": [px(x0, zt), px(x1, zb)], "res": [R.resolution_x, R.resolution_y]}
    if quad:                                        # screen corners on a tilted lid: TL, TR, BR, BL in image pixels
        def pw(v):
            co = world_to_camera_view(scn, cam, v); return [co.x * R.resolution_x, (1 - co.y) * R.resolution_y]
        out["quad"] = [pw(v) for v in quad]
    json.dump(out, open(os.path.join(OUT, f"{NAME}-boxes.json"), "w"))
    if os.environ.get("GLASS") and glass_box:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from glass import glass_pass
        glass_pass(scn, cam, *glass_box, OUT, NAME)
        return
    for o in bpy.data.objects:
        if o.type == "MESH" and o.name != "holdout" and not o.is_shadow_catcher:
            for poly in o.data.polygons: poly.use_smooth = True
            if hasattr(o.data, "set_sharp_from_angle"): o.data.set_sharp_from_angle(angle=math.radians(35))
    bpy.ops.render.render(write_still=True)


# ======================= Macintosh 128K =======================
def mac128():
    H = 1.309                                   # measured on the front render, case width = 1
    def zv(v): return H - v * U                 # page v (from the top) -> z
    beige = mat("beige", (218, 209, 187), rough=0.48)
    dark = mat("slot", (20, 18, 16), rough=0.7, grain=0)
    case = box("case", 0, 1.0, 0, H, 0, 1.0, m=beige)
    b = case.modifiers.new("bevel", "BEVEL"); b.width = 0.02; b.segments = 8; b.limit_method = "ANGLE"; apply_mods(case)
    # square recessed frame: a wide shallow slope into the tube
    cut(case, box("recess", 0.088, 0.912, zv(75.8), zv(14.5), -0.1, 0.010, bevel=0.022, seg=10))
    cut(case, box("glass", 0.118, 0.882, zv(73.0), zv(16.1), -0.1, 0.08, bevel=0.03, seg=10))
    box("tube", 0.11, 0.89, zv(73.5), zv(15.6), 0.07, 0.08, m=mat("tube", (8, 8, 8), rough=0.15, grain=0))
    holdout(0.118, 0.882, zv(73.0), zv(16.1), 0.06)
    # floppy slot with its thicker eject end
    box("plate", 0.795, 0.896, zv(95.2), zv(91.0), -0.0018, 0.004, bevel=0.0012, seg=3, m=beige)
    cut(case, box("slot", 0.508, 0.879, zv(94.15), zv(92.05), -0.1, 0.03, bevel=0.003, seg=4), keep_mat=dark)
    # the lower band sits slightly back, with a groove above it
    cut(case, box("band", -0.1, 1.1, -0.1, zv(116.7), -0.1, 0.0025))
    cut(case, box("groove", -0.1, 1.1, zv(116.9), zv(116.5), -0.1, 0.005))
    cut(case, box("jackplate", 0.84, 0.904, zv(126.4), zv(119.4), -0.1, 0.0060, bevel=0.002, seg=3))
    cut(case, box("jack", 0.854, 0.888, zv(124.9), zv(121.0), -0.1, 0.03, bevel=0.0015, seg=3), keep_mat=dark)
    studio(center_z=H / 2)
    floor(0.0)
    cam = camera(H, 0.0, 2320, 2960, 1.2, 0.02, screen_cz=zv((16.1 + 73.0) / 2), real_w=0.244)
    finish(cam, (0, H, 1.0, 0), glass_box=(0.118, 0.882, zv(73.0), zv(16.1)))


# ======================= iBook G4 12" =======================
# Scene width 1 = 28.5 cm (Apple spec). Lid face 0.796 tall; screen 24.6 x 18.4 cm. Lid about 0.8 cm thick,
# base about 2.6 cm. The lid leans back 18 degrees from vertical, as an open laptop does; the page warps
# the live screen to the projected corners this script writes out.
def ibook():
    H = 0.7963
    LIDONLY = bool(os.environ.get("LIDONLY"))         # B side only: the lid face-on, no deck
    TILT = 0.0 if LIDONLY else math.radians(18)
    def zv(v): return H - v * U
    white = mat("white", (238, 238, 235), rough=0.40, coat=0.08, grain=0.02, sss=0.08)
    keyw = mat("keys", (242, 242, 240), rough=0.35, coat=0.15, grain=0.01, sss=0.12)
    grey = mat("bumper", (200, 200, 200), rough=0.7, grain=0)
    dark = mat("dark", (22, 22, 22), rough=0.5, grain=0)
    before = set(bpy.data.objects)
    LT = 0.028                                   # lid thickness (0.8 cm)
    lid = box("lid", 0, 1.0, 0, H, 0, LT, m=white)
    b = lid.modifiers.new("bevel", "BEVEL"); b.width = 0.010; b.segments = 6; b.limit_method = "ANGLE"; apply_mods(lid)
    cut(lid, box("rim", 0.0075, 0.9925, 0.0075, H - 0.0075, -0.1, 0.0007, bevel=0.0012, seg=3))
    cut(lid, box("screen", 0.065, 0.935, zv(72.08), zv(6.65), -0.1, 0.012, bevel=0.0015, seg=3))
    box("panel", 0.06, 0.94, zv(72.6), zv(6.1), 0.010, 0.014, m=mat("panel", (6, 6, 6), rough=0.2, grain=0, sss=0))
    hold = holdout(0.065, 0.935, zv(72.08), zv(6.65), 0.008)
    cut(lid, box("latch", 0.473, 0.527, zv(2.4), zv(1.8), -0.1, 0.004, bevel=0.0025, seg=4), keep_mat=dark)
    for x in (0.023, 0.977):
        cyl("bumper", x, zv(3.2), 0.0062, -0.0012, 0.001, bevel=0.0008, m=grey)
    cut(lid, cyl("led", 0.966, zv(22.5), 0.003, -0.1, 0.004), keep_mat=dark)
    lid_objs = [o for o in bpy.data.objects if o not in before]
    # hinge: lid pivots about its bottom edge, which sits on the hinge barrel at the back of the deck
    bpy.ops.object.empty_add(location=(0, LT / 2, 0.0)); piv = bpy.context.object
    for o in lid_objs:
        o.parent = piv; o.matrix_parent_inverse = piv.matrix_world.inverted()
    piv.rotation_euler = (-TILT, 0, 0); piv.location = (0, 0.012, 0.012)
    bpy.context.view_layer.update()
    sx0, sx1, st, sb = 0.065, 0.935, zv(6.65), zv(72.08)
    quad = [hold.matrix_world @ Vector(p) for p in [(sx0, 0.008, st), (sx1, 0.008, st), (sx1, 0.008, sb), (sx0, 0.008, sb)]]
    if LIDONLY:
        for o in lid_objs: o.parent = None
        studio(center_z=H / 2)
        floor(0.0)
        cam = camera(H, 0.0, 2400, 2200, 1.2, 0.0, screen_cz=(st + sb) / 2, real_w=0.285)
        finish(cam, (0, H, 1.0, 0))
        return
    cyl("hinge", 0.5, -0.004, 0.016, -0.02, 0.04, m=white).rotation_euler = (0, math.pi / 2, 0)
    bpy.context.object.scale = (1, 1, 0.40 / 0.06)
    # base: 28.5 x 23.0 cm footprint, 2.6 cm thick, rounded front edge; seam between top and bottom shells
    base = box("base", 0.0, 1.0, -0.091, -0.004, -0.807, 0.0, m=white)
    cut(base, box("seam", -0.1, 1.1, -0.049, -0.047, -0.9, -0.80))
    bb = base.modifiers.new("bevel", "BEVEL"); bb.width = 0.022; bb.segments = 10; bb.limit_method = "ANGLE"; apply_mods(base)
    # keyboard: a half-height function row and five full rows, ~1.6 cm pitch (0.056), white keys over a grey bed
    kb_x0, kb_x1 = 0.045, 0.955
    cut(base, box("kbwell", kb_x0, kb_x1, -0.012, 0.1, -0.352, -0.030, bevel=0.003, seg=3), keep_mat=mat("kbbed", (150, 150, 148), rough=0.6, grain=0, sss=0))
    pitch = (kb_x1 - kb_x0) / 16.0
    rows = [(-0.030 - 0.026, 16, 0.024)] + [(-0.060 - i * 0.0585, n, 0.051) for i, n in enumerate((15, 15, 14, 13, 12))]
    for y_top, n, depth in rows:
        unit = (kb_x1 - kb_x0 - 0.004) / n
        for c in range(n):
            x = kb_x0 + 0.002 + c * unit
            box("key", x + 0.0035, x + unit - 0.0035, -0.0110, -0.0042, y_top - depth, y_top, bevel=0.0028, seg=3, m=keyw)
    # trackpad 6.6 x 4.8 cm, centred, its front edge 2.4 cm from the front
    tw, td, tf = 0.232, 0.168, 0.807 - 0.084
    cut(base, box("pad", 0.5 - tw / 2, 0.5 + tw / 2, -0.0055, 0.1, -tf, -tf + td, bevel=0.004, seg=4), keep_mat=mat("pad", (228, 228, 226), rough=0.55, grain=0))
    box("padbtn", 0.5 - 0.11, 0.5 + 0.11, -0.0075, -0.0035, -tf - 0.050, -tf - 0.008, bevel=0.003, seg=3, m=keyw)
    # latch release on the front face
    cut(base, box("btnwell", 0.44, 0.56, -0.066, -0.050, -0.85, -0.802, bevel=0.007, seg=6))
    box("button", 0.445, 0.555, -0.064, -0.052, -0.807, -0.800, bevel=0.0055, seg=6, m=mat("btn", (70, 72, 76), rough=0.25, coat=0.6, grain=0))
    studio(center_z=H / 2)
    floor(-0.091)
    sc = (quad[0].z + quad[2].z) / 2
    cam = camera(H, -0.12, 2600, 2560, 1.25, -0.05, screen_cz=sc, real_w=0.285)
    finish(cam, (0, H, 1.0, 0), quad=quad)


# ======================= iMac G5 17" (2005) =======================
def imac():
    """17-inch iMac G5: 42.6 cm wide, 43.0 cm tall with the foot (Apple's spec page SP69). Front
    proportions from a straight-on photo of a Rev. A 17-inch (Wikimedia Commons, "IMac G5 Rev. A
    front.jpg"): case 0.837 of the width tall, black opening 0.057 in from each side and 0.06 from the
    top. The 16:10 active area is the spec's 36.6 cm (0.859), so a thin black border rings it.
    Foot from "Apple iMac G5 side rear view-2005-05-16.jpg": one aluminium strip leaves the back of
    the case near mid-height, runs down and BACKWARD, and bends forward into a flat plate under the
    case. From the front only its lower part shows, widening downward."""
    import bmesh
    CH = 0.837
    OB = 0.057; TB = 0.06
    AW = 0.366 / 0.426; AH = AW * 0.625            # active area
    RING = (1 - 2 * OB - AW) / 2                   # black border around the active area
    F = 0.430 / 0.426 - CH                          # foot drop below the case
    def zv(v): return CH - v * U
    white = mat("white", (240, 240, 237), rough=0.32, coat=0.25, grain=0.015, sss=0.10)
    DEP = 0.12
    case = box("case", 0, 1.0, 0, CH, 0, DEP, m=white)
    b = case.modifiers.new("bevel", "BEVEL"); b.width = 0.020; b.segments = 8; b.limit_method = "ANGLE"; apply_mods(case)
    oz1 = CH - TB; oz0 = oz1 - AH - 2 * RING
    cut(case, box("screen", OB, 1 - OB, oz0, oz1, -0.1, 0.002, bevel=0.0008, seg=3), keep_mat=mat("ring", (10, 10, 10), rough=0.3, grain=0, sss=0))
    box("panel", OB - 0.01, 1 - OB + 0.01, oz0 - 0.01, oz1 + 0.01, 0.002, 0.008, m=mat("panel", (8, 8, 8), rough=0.15, grain=0, sss=0))
    sx0, sx1 = OB + RING, 1 - OB - RING
    sz1 = oz1 - RING; sz0 = sz1 - AH
    holdout(sx0, sx1, sz0, sz1, 0.0015)
    box("grille", 0.055, 0.945, -0.002, 0.004, 0.012, 0.10, m=mat("grille", (120, 120, 120), rough=0.8, grain=0, sss=0))
    alu = mat("alu", (214, 216, 219), rough=0.48, metal=0.9, grain=0.02, sss=0)
    zt, zb, r = 0.36, -F + 0.006, 0.06
    y_top, y_bend = DEP + 0.004, DEP + 0.27         # leg leaves the back, runs down and backward
    # leg line from (y_top, zt) to the start of the bend, then a quarter-ish arc, then the plate forward
    # leg from the back of the case to the corner (y_bend, zb), plate from the corner forward to y=0.02;
    # the corner is rounded with a quadratic Bezier r long on each side
    L = math.hypot(y_bend - y_top, zt - zb); ux, uz = (y_bend - y_top) / L, (zb - zt) / L
    pa = (y_bend - ux * r, zb - uz * r); pb = (y_bend - r, zb)
    pts = [(y_top + (pa[0] - y_top) * t / 15, zt + (pa[1] - zt) * t / 15) for t in range(16)]
    for k in range(1, 13):
        t = k / 12
        pts.append(((1 - t) ** 2 * pa[0] + 2 * (1 - t) * t * y_bend + t * t * pb[0],
                    (1 - t) ** 2 * pa[1] + 2 * (1 - t) * t * zb + t * t * pb[1]))
    for k in range(1, 12): pts.append((pb[0] - (pb[0] - 0.02) * k / 11, zb))
    n = len(pts)
    bm = bmesh.new(); rows = []
    W0, W1 = 0.235, 0.36
    for i, (y, z) in enumerate(pts):
        t = max(0.0, min(1.0, (zt - z) / (zt - zb)))  # width grows linearly with depth below the attachment
        w = W0 + (W1 - W0) * t
        rows.append((bm.verts.new((0.5 - w / 2, y, z)), bm.verts.new((0.5 + w / 2, y, z))))
    for i in range(n - 1):
        bm.faces.new((rows[i][0], rows[i + 1][0], rows[i + 1][1], rows[i][1]))
    me = bpy.data.meshes.new("foot"); bm.to_mesh(me); bm.free()
    foot = bpy.data.objects.new("foot", me); bpy.context.collection.objects.link(foot)
    sol = foot.modifiers.new("sol", "SOLIDIFY"); sol.thickness = 0.012; sol.offset = 0
    fb = foot.modifiers.new("bevel", "BEVEL"); fb.width = 0.004; fb.segments = 4; fb.limit_method = "ANGLE"
    foot.data.materials.append(alu); apply_mods(foot)
    studio(center_z=CH / 2)
    floor(zb - 0.006)
    cam = camera(CH, zb - 0.006, 2320, 2600, 1.2, 0.0, screen_cz=(sz0 + sz1) / 2, real_w=0.426)
    json.dump({"screen": [sx0, CH - sz1, sx1, CH - sz0]}, open(os.path.join(OUT, "imac-screen.json"), "w"))
    finish(cam, (0, CH, 1.0, 0))


# ======================= black LCD =======================
def lcd():
    SB, TB, BB = 0.059, 0.064, 0.096            # bezels as fractions of the case width (15" 4:3 LCD, about 34.5 cm wide)
    W_IN = 1 - 2 * SB
    H = TB + W_IN * 0.75 + BB
    def zv(v): return H - v * U
    black = mat("black", (22, 22, 24), rough=0.42, coat=0.1, grain=0.02, sss=0)
    case = box("case", 0, 1.0, 0, H, 0, 0.055, m=black)
    b = case.modifiers.new("bevel", "BEVEL"); b.width = 0.012; b.segments = 6; b.limit_method = "ANGLE"; apply_mods(case)
    sx0, sx1, sz0, sz1 = SB, 1 - SB, BB, H - TB
    cut(case, box("step", sx0 - 0.008, sx1 + 0.008, sz0 - 0.008, sz1 + 0.008, -0.1, 0.004, bevel=0.003, seg=3))
    cut(case, box("screen", sx0, sx1, sz0, sz1, -0.1, 0.1, bevel=0.0015, seg=2))
    box("panel", sx0 - 0.01, sx1 + 0.01, sz0 - 0.01, sz1 + 0.01, 0.02, 0.025, m=mat("panel", (4, 4, 4), rough=0.2, grain=0, sss=0))
    holdout(sx0, sx1, sz0, sz1, 0.015)
    for i in range(4):                          # menu buttons along the bottom bezel, right side
        x = 0.70 + i * 0.045
        cut(case, box("bwell", x - 0.012, x + 0.012, BB / 2 - 0.006, BB / 2 + 0.006, -0.1, 0.003, bevel=0.002, seg=3))
        box("btn", x - 0.010, x + 0.010, BB / 2 - 0.004, BB / 2 + 0.004, -0.0015, 0.003, bevel=0.002, seg=3, m=black)
    bpy.ops.mesh.primitive_uv_sphere_add(radius=0.0045, location=(0.90, -0.001, BB / 2))
    led = bpy.context.object; led.scale = (1, 0.5, 1)
    led.data.materials.append(mat("led", (60, 140, 255), rough=0.2, grain=0, sss=0, emit=(0.25, 0.55, 1.0)))
    box("neck", 0.43, 0.57, -0.17, 0.25, 0.07, 0.12, bevel=0.012, m=black)
    bpy.ops.mesh.primitive_cylinder_add(vertices=128, radius=1, depth=0.022, location=(0.5, 0.06, -0.17))
    foot = bpy.context.object; foot.scale = (0.21, 0.15, 1)
    fb = foot.modifiers.new("bevel", "BEVEL"); fb.width = 0.009; fb.segments = 6; fb.limit_method = "ANGLE"; apply_mods(foot)
    foot.data.materials.append(black)
    studio(center_z=H / 2)
    floor(-0.181)
    cam = camera(H, -0.181, 2320, 2400, 1.2, 0.0, screen_cz=(sz0 + sz1) / 2, real_w=0.345)
    finish(cam, (0, H, 1.0, 0))


globals()[NAME]()
print("done", NAME)
