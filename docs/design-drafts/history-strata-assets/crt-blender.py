"""Beige CRT for history-strata.html, modelled from measured proportions and rendered in Cycles.

Units: 1 Blender metre = 100 page units (case width = 1.0 m). Front face at y = 0, facing -Y.
Page coordinates: u = x * 100, v = (CASE_H - z) * 100 with the case's top at z = CASE_H.
The screen opening gets a holdout plane so it renders transparent.
Run: blender -b --factory-startup --python crt.py -- OUTDIR [samples]
"""
import bpy, bmesh, math, sys, json, os
from mathutils import Vector
from bpy_extras.object_utils import world_to_camera_view

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = argv[0] if argv else "/tmp"
SAMPLES = int(argv[1]) if len(argv) > 1 else 160
U = 0.01                      # one page unit in metres
CASE_H = 90.4 * U            # 15" CRT: about 36.5 cm wide, 33 cm tall without the base
DEPTH = 0.42                  # front shell depth (m)

bpy.ops.wm.read_factory_settings(use_empty=True)
scn = bpy.context.scene


def srgb(c):
    c = c / 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def mat_plastic(name, rgb, rough=0.42, spec=0.5, coat=0.0):
    m = bpy.data.materials.new(name); m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*[srgb(x) for x in rgb], 1)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Specular IOR Level"].default_value = spec
    b.inputs["Coat Weight"].default_value = coat
    # fine moulding texture: tiny bump from noise
    nt = m.node_tree
    tex = nt.nodes.new("ShaderNodeTexNoise"); tex.inputs["Scale"].default_value = 900; tex.inputs["Detail"].default_value = 2
    bump = nt.nodes.new("ShaderNodeBump"); bump.inputs["Strength"].default_value = 0.04; bump.inputs["Distance"].default_value = 0.0004
    nt.links.new(tex.outputs["Fac"], bump.inputs["Height"]); nt.links.new(bump.outputs["Normal"], b.inputs["Normal"])
    return m


def box(name, x0, x1, z0, z1, y0, y1, bevel=0.0, seg=6, mat=None):
    bpy.ops.mesh.primitive_cube_add(size=1, location=((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2))
    o = bpy.context.object; o.name = name
    o.scale = (x1 - x0, y1 - y0, z1 - z0)
    bpy.ops.object.transform_apply(scale=True)
    if bevel:
        mod = o.modifiers.new("bevel", "BEVEL"); mod.width = bevel; mod.segments = seg; mod.limit_method = "ANGLE"
    if mat: o.data.materials.append(mat)
    return o


def cyl(name, x, z, r, y0, y1, verts=96, bevel=0.0, mat=None):
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=r, depth=y1 - y0, location=(x, (y0 + y1) / 2, z), rotation=(math.pi / 2, 0, 0))
    o = bpy.context.object; o.name = name
    if bevel:
        mod = o.modifiers.new("bevel", "BEVEL"); mod.width = bevel; mod.segments = 6; mod.limit_method = "ANGLE"
    if mat: o.data.materials.append(mat)
    return o


def apply_mods(o):
    bpy.context.view_layer.objects.active = o
    for m in list(o.modifiers):
        bpy.ops.object.modifier_apply(modifier=m.name)


def cut(target, cutter):
    apply_mods(cutter)
    mod = target.modifiers.new("cut", "BOOLEAN"); mod.operation = "DIFFERENCE"; mod.object = cutter; mod.solver = "EXACT"
    apply_mods(target)
    bpy.data.objects.remove(cutter, do_unlink=True)


beige = mat_plastic("beige", (226, 223, 210), rough=0.44)
dark = mat_plastic("socket", (60, 56, 44), rough=0.6)

# ---------- case: a deep beige shell with rounded edges ----------
case = box("case", 0, 1.0, 0, CASE_H, 0, DEPTH, mat=beige)
# subdivide so the front can bow out slightly (the moulded bezel is convex)
bpy.context.view_layer.objects.active = case
bpy.ops.object.mode_set(mode="EDIT"); bpy.ops.mesh.subdivide(number_cuts=24); bpy.ops.object.mode_set(mode="OBJECT")
for v in case.data.vertices:
    if v.co.y < 0.001:                                  # front vertices bow toward the viewer
        dx = (v.co.x - 0.5) / 0.52
        v.co.y -= 0.030 * max(0.0, 1 - dx * dx)
        v.co.y += 0.03 * max(0.0, (abs(dx) - 0.86) / 0.14) ** 2      # the sides roll back
    # the top edge rises in the middle (measured: about 2 units)
    if v.co.z > CASE_H - 0.001:
        dx = (v.co.x - 0.5) / 0.5
        v.co.z += 0.02 * max(0.0, 1 - dx * dx)
bev = case.modifiers.new("bevel", "BEVEL"); bev.width = 0.007; bev.segments = 6; bev.limit_method = "ANGLE"; bev.angle_limit = math.radians(40)
apply_mods(case)

# ---------- back housing: the tube's body tapers back behind the bezel ----------
import bmesh as _bm
bmb = _bm.new()
f0 = [(0.03, DEPTH, 0.02), (0.97, DEPTH, 0.02), (0.97, DEPTH, CASE_H - 0.02), (0.03, DEPTH, CASE_H - 0.02)]
f1 = [(0.20, 1.02, 0.10), (0.80, 1.02, 0.10), (0.80, 1.02, CASE_H - 0.17), (0.20, 1.02, CASE_H - 0.17)]
v0 = [bmb.verts.new(p) for p in f0]; v1 = [bmb.verts.new(p) for p in f1]
for i in range(4):
    bmb.faces.new((v0[i], v0[(i + 1) % 4], v1[(i + 1) % 4], v1[i]))
bmb.faces.new(v1[::-1])
meb = bpy.data.meshes.new("back"); bmb.to_mesh(meb); bmb.free()
back = bpy.data.objects.new("back", meb); bpy.context.collection.objects.link(back)
bkb = back.modifiers.new("bevel", "BEVEL"); bkb.width = 0.03; bkb.segments = 8; bkb.limit_method = "ANGLE"
back.data.materials.append(beige); apply_mods(back)
for p_ in back.data.polygons: p_.use_smooth = True

# ---------- screen surround: a flat stepped ring, then a narrow chamfer down to the glass (after the icon) ----------
ox0, ox1 = 10.0 * U, 90.0 * U            # tube glass; the lit picture is 76.4 % of the width (28 cm of 36.5)
oz0, oz1 = CASE_H - 70.4 * U, CASE_H - 9.5 * U
cut(case, box("step", ox0 - 0.022, ox1 + 0.022, oz0 - 0.022, oz1 + 0.022, -0.08, 0.005, bevel=0.0025, seg=3))
cut(case, box("hole", ox0, ox1, oz0, oz1, -0.1, 0.06, bevel=0.007, seg=2))
tube = box("tube", ox0 - 0.02, ox1 + 0.02, oz0 - 0.02, oz1 + 0.02, 0.05, 0.06, mat=mat_plastic("tube", (6, 6, 6), rough=0.15))
hold = box("holdout", ox0 + 0.004, ox1 - 0.004, oz0 + 0.004, oz1 - 0.004, 0.035, 0.04)
hm = bpy.data.materials.new("holdout"); hm.use_nodes = True
nt = hm.node_tree; nt.nodes.clear(); out = nt.nodes.new("ShaderNodeOutputMaterial"); ho = nt.nodes.new("ShaderNodeHoldout")
nt.links.new(ho.outputs[0], out.inputs["Surface"]); hold.data.materials.append(hm)

# ---------- chin: real monitor buttons are low caps that stand a couple of millimetres proud of the
# flat front, lit on top and casting a small shadow below. No wells, no gaps around them.
cz = CASE_H - 80.6 * U
capm = mat_plastic("cap", (230, 228, 216), rough=0.36)
greym = mat_plastic("glyph", (118, 116, 108), rough=0.6)
def front_y(x):
    """Where the bowed front surface is at this x (it comes up to 3 cm toward the viewer at the centre)."""
    dx = (x - 0.5) / 0.52
    return -0.030 * max(0.0, 1 - dx * dx) + 0.03 * max(0.0, (abs(dx) - 0.86) / 0.14) ** 2
def button(x, r, rise):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=96, ring_count=48, radius=1, location=(x, front_y(x) + 0.0006, cz))
    b_ = bpy.context.object; b_.scale = (r, rise, r)          # a flattened dome: rises `rise` toward the viewer
    b_.data.materials.append(capm)
    for p_ in b_.data.polygons: p_.use_smooth = True
    return b_
for i in range(4):
    x = (41.45 + 5.6 * i) * U
    button(x, 1.75 * U, 0.0024)
    fy = front_y(x); box("dash", x - 0.0018, x + 0.0018, cz - 0.0005, cz + 0.0005, fy - 0.0022, fy - 0.0014, mat=greym)
button(70.35 * U, 2.75 * U, 0.0030)
fy = front_y(70.35 * U)
bpy.ops.mesh.primitive_torus_add(major_radius=0.80 * U, minor_radius=0.07 * U, location=(70.35 * U, fy - 0.0026, cz), rotation=(math.pi / 2, 0, 0))
ring = bpy.context.object; ring.data.materials.append(greym)
box("bar", 70.28 * U, 70.42 * U, cz + 0.1 * U, cz + 1.1 * U, fy - 0.0030, fy - 0.0021, mat=greym)
bpy.ops.mesh.primitive_uv_sphere_add(segments=48, ring_count=24, radius=0.48 * U, location=(64.55 * U, front_y(64.55 * U) + 0.0004, cz))
led = bpy.context.object; led.scale = (1, 0.45, 1)
lm = bpy.data.materials.new("led"); lm.use_nodes = True
lb = lm.node_tree.nodes["Principled BSDF"]; lb.inputs["Base Color"].default_value = (1, 0.55, 0.08, 1)
lb.inputs["Roughness"].default_value = 0.15
lb.inputs["Emission Color"].default_value = (1, 0.6, 0.1, 1); lb.inputs["Emission Strength"].default_value = 2.5
led.data.materials.append(lm)

# ---------- stand: a wide flat swivel bowl and a thin X-shaped foot with concave edges (after the icon) ----------
import bmesh
SY = DEPTH * 0.55
bpy.ops.mesh.primitive_uv_sphere_add(segments=128, ring_count=64, radius=1, location=(0.5, SY, -0.006))
bowl = bpy.context.object; bowl.scale = (0.255, 0.20, 0.058); bowl.data.materials.append(beige)
bpy.ops.mesh.primitive_uv_sphere_add(segments=128, ring_count=64, radius=1, location=(0.5, SY, -0.040))
bowl2 = bpy.context.object; bowl2.scale = (0.19, 0.15, 0.040); bowl2.data.materials.append(beige)
neck = cyl("neck", 0.5, -0.07, 0.08, SY - 0.05, SY + 0.05, mat=beige)
neck.location = (0.5, SY, -0.075); neck.scale = (1.2, 1.2, 0.8)
# real tilt-swivel base: a round, slightly domed disc under the bowl
bpy.ops.mesh.primitive_cylinder_add(vertices=160, radius=1, depth=0.024, location=(0.5, SY, -0.116))
foot = bpy.context.object; foot.scale = (0.25, 0.22, 1)
fb = foot.modifiers.new("bevel", "BEVEL"); fb.width = 0.010; fb.segments = 6; fb.limit_method = "ANGLE"
foot.data.materials.append(beige); apply_mods(foot)
for p_ in foot.data.polygons: p_.use_smooth = True

bpy.ops.object.select_all(action="DESELECT")
for o in bpy.data.objects:
    if o.type == "MESH" and o.name not in ("holdout",):
        bpy.context.view_layer.objects.active = o
        o.select_set(True)
        bpy.ops.object.shade_auto_smooth(angle=math.radians(35)) if hasattr(bpy.ops.object, "shade_auto_smooth") else None
        o.select_set(False)

# ---------- floor: shadow catcher ----------
bpy.ops.mesh.primitive_plane_add(size=6, location=(0.5, 0.5, -0.128))
floor = bpy.context.object; floor.is_shadow_catcher = True

# ---------- light: a studio softbox above-left-front, a fill, a top strip, a dim grey world ----------
def area(name, loc, size, power, target=(0.5, 0.2, CASE_H / 2)):
    bpy.ops.object.light_add(type="AREA", location=loc)
    l = bpy.context.object; l.name = name; l.data.size = size; l.data.energy = power
    d = Vector(target) - Vector(loc); l.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    return l
area("key", (-1.2, -2.6, 2.6), 2.2, float(os.environ.get("KEY", "320")))
area("fill", (2.4, -2.4, 0.9), 2.0, float(os.environ.get("FILL", "70")))
area("top", (0.5, -0.6, 3.2), 3.0, float(os.environ.get("TOP", "130")))
world = bpy.data.worlds.new("w"); scn.world = world; world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.22, 0.22, 0.23, 1)

# ---------- camera: the shared museum camera (level, shift lens, 100 mm, eye 8 degrees above the screen centre) ----------
sensor, frame_w = 36.0, 1.2
Dcam = 1.5 / 0.365                 # the shared rule: photographed from 1.5 m in real life (case 36.5 cm wide)
lens = Dcam * sensor / frame_w
eye = (oz0 + oz1) / 2 + Dcam * math.tan(math.radians(float(os.environ.get("ELEV", "8"))))   # 8 degrees above the screen centre
bpy.ops.object.camera_add()
cam = bpy.context.object; scn.camera = cam
cam.data.type = "PERSP"; cam.data.lens = lens; cam.data.sensor_width = sensor; cam.data.sensor_fit = "HORIZONTAL"
cam.location = (0.5, -Dcam, eye); cam.rotation_euler = (math.pi / 2, 0, 0)
cam.data.shift_y = ((CASE_H - 0.128) / 2 - eye) / frame_w
R = scn.render
R.engine = "CYCLES"; scn.cycles.device = "GPU"; scn.cycles.samples = SAMPLES; scn.cycles.use_denoising = True
prefs = bpy.context.preferences.addons["cycles"].preferences
prefs.compute_device_type = "METAL"; prefs.get_devices()
for d in prefs.devices: d.use = True
R.film_transparent = True
R.resolution_x = 2320; R.resolution_y = 2380; R.resolution_percentage = int(os.environ.get("PCT", "100"))
scn.view_settings.view_transform = "Standard"; scn.view_settings.exposure = float(os.environ.get("EXPO", "-1.5"))
R.image_settings.file_format = "PNG"; R.image_settings.color_mode = "RGBA"
R.filepath = os.path.join(OUT, "crt-full.png")

# where the page boxes land in the image (front-face corners projected)
bpy.context.view_layer.update()
def px(x, z, y=0.0):
    co = world_to_camera_view(scn, cam, Vector((x, y, z)))
    return [co.x * R.resolution_x, (1 - co.y) * R.resolution_y]
boxes = {"case": [px(0, CASE_H), px(1.0, 0)], "page": [px(0, CASE_H), px(1.0, 0)]}
json.dump(boxes, open(os.path.join(OUT, "crt-boxes.json"), "w"))
if os.environ.get("GLASS"):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from glass import glass_pass
    glass_pass(scn, cam, ox0, ox1, oz0, oz1, OUT, "crt")
else:
    bpy.ops.render.render(write_still=True)
print("done", boxes)
