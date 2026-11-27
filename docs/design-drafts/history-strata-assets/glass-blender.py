"""Convex CRT glass, reflection only. Imported by crt.py / machines.py when GLASS=1:
removes every mesh, puts a bulged glass sheet over the tube opening and renders what it reflects
(the studio's softboxes and gradient), on black, for a 'screen' blend over the live page screen."""
import bpy, bmesh, math, json, os
from mathutils import Vector
from bpy_extras.object_utils import world_to_camera_view


def glass_pass(scn, cam, x0, x1, z0, z1, out, name, bulge=0.028):
    for o in list(bpy.data.objects):
        if o.type == "MESH":
            bpy.data.objects.remove(o, do_unlink=True)
    bm = bmesh.new()
    N = 64
    verts = [[None] * (N + 1) for _ in range(N + 1)]
    for i in range(N + 1):
        for j in range(N + 1):
            u, v = i / N * 2 - 1, j / N * 2 - 1
            x = x0 + (x1 - x0) * (i / N); z = z0 + (z1 - z0) * (j / N)
            y = 0.012 - bulge * (1 - 0.55 * u * u) * (1 - 0.55 * v * v)     # a shallow dome, as a tube face is
            verts[i][j] = bm.verts.new((x, y, z))
    for i in range(N):
        for j in range(N):
            bm.faces.new((verts[i][j], verts[i + 1][j], verts[i + 1][j + 1], verts[i][j + 1]))
    me = bpy.data.meshes.new("glass"); bm.to_mesh(me); bm.free()
    g = bpy.data.objects.new("glass", me); bpy.context.collection.objects.link(g)
    for p in me.polygons: p.use_smooth = True
    m = bpy.data.materials.new("glass"); m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (0.0, 0.0, 0.0, 1)
    b.inputs["Roughness"].default_value = 0.07
    b.inputs["Specular IOR Level"].default_value = 0.55
    b.inputs["Coat Weight"].default_value = 0.4; b.inputs["Coat Roughness"].default_value = 0.03
    g.data.materials.append(m)
    # a softbox behind and above-left of the camera, invisible to the camera itself: what a tube
    # face actually mirrors in a studio photo is the big light near the lens, not the key at the side
    cx, cy, cz = cam.location
    bpy.ops.mesh.primitive_plane_add(size=1, location=(cx - 0.42, cy - 0.30, cz + 0.16))
    card = bpy.context.object; card.scale = (1.9, 1.3, 1.0)
    d = Vector(((x0 + x1) / 2 - card.location.x, 0.0 - card.location.y, (z0 + z1) / 2 - card.location.z))
    card.rotation_euler = d.to_track_quat("Z", "Y").to_euler()
    em = bpy.data.materials.new("card"); em.use_nodes = True; nt = em.node_tree; nt.nodes.clear()
    o = nt.nodes.new("ShaderNodeOutputMaterial"); e = nt.nodes.new("ShaderNodeEmission"); e.inputs["Strength"].default_value = 3.2
    tc = nt.nodes.new("ShaderNodeTexCoord"); gr = nt.nodes.new("ShaderNodeTexGradient"); gr.gradient_type = "SPHERICAL"
    mp = nt.nodes.new("ShaderNodeMapping"); mp.inputs["Location"].default_value = (-1.0, -1.0, 0); mp.inputs["Scale"].default_value = (2.0, 2.0, 1)   # generated 0..1 -> -1..1, bright at the centre
    rp = nt.nodes.new("ShaderNodeValToRGB"); rp.color_ramp.elements[0].position = 0.05; rp.color_ramp.elements[1].position = 0.6
    nt.links.new(tc.outputs["Generated"], mp.inputs["Vector"]); nt.links.new(mp.outputs["Vector"], gr.inputs["Vector"])
    nt.links.new(gr.outputs["Fac"], rp.inputs["Fac"]); nt.links.new(rp.outputs["Color"], e.inputs["Color"]); nt.links.new(e.outputs[0], o.inputs["Surface"])
    card.data.materials.append(em); card.visible_camera = False
    scn.render.film_transparent = False
    w = bpy.data.worlds.new("black"); scn.world = w; w.use_nodes = True        # highlights only: black stays black under a screen blend
    w.node_tree.nodes["Background"].inputs[0].default_value = (0, 0, 0, 1)
    bpy.context.view_layer.update()
    R = scn.render
    def px(x, z):
        co = world_to_camera_view(scn, cam, Vector((x, 0.0, z)))
        return [co.x * R.resolution_x, (1 - co.y) * R.resolution_y]
    json.dump({"op": [px(x0, z1), px(x1, z0)]}, open(os.path.join(out, f"{name}-glass-box.json"), "w"))
    R.filepath = os.path.join(out, f"{name}-glass-full.png")
    bpy.ops.render.render(write_still=True)
