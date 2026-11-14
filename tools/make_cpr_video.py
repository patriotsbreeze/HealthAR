"""Renders a short video of CPR hand position and compressions with the app's blue glass hands.

Run with Blender, headless:

    blender -b --python tools/make_cpr_video.py -- out.mp4

About 8 seconds at 30 FPS, square, captioned, seen from above as the rescuer sees their own hands.
It opens on the grip, since that's the point:

1. The heel of one hand is already on the centre of the chest, and the other drops onto it.
2. Its fingers curl down and lace while the lower hand's lift off the chest, by about 1.3 s.
3. A beat on the finished grip, then compressions: 5 cm deep at 110 a minute.

With --clip it writes only the first 2 seconds, the grip, uncaptioned at 480 x 480, for the app's
corner reminder as CPR starts, and a still of the finished grip beside it for Reduce Motion:

    blender -b --python tools/make_cpr_video.py -- GripReminder.mp4 --clip

Captions follow AHA 2025 adult BLS wording loosely and are DRAFT until a clinician signs them,
like every line in the app. The hands are built here from the same pieces as tools/make_ghost_model.py,
but jointed, so the fingers can move.
"""

import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_ghost_model as g  # noqa: E402

FPS = 30
BEAT = FPS * 60 / 110  # frames per compression
DEPTH = 0.05
OUT = os.path.abspath(next((a for a in sys.argv if a.endswith(".mp4")), "cpr_hand_position.mp4"))

CAPTIONS = [
    (0, 16, "Heel of one hand on the center of the chest"),
    (16, 66, "Other hand on top. Lace your fingers and lift them off the chest"),
    (66, 240, "Push hard and fast: 2 inches deep, 100 to 120 a minute"),
]
LAST_FRAME = 240
# The reminder: the top hand comes down and laces in by frame 40, then the grip holds to the loop.
CLIP = "--clip" in sys.argv
CLIP_FRAMES = 60


# --- Jointed hands -------------------------------------------------------------------------------


def pivot(obj, joint):
    """Moves the object's origin to `joint`, model space, without moving its mesh."""
    j = Vector(g.blender(joint))
    obj.data.transform(Matrix.Translation(-j))
    obj.location = j
    return obj


def parent(child, to):
    child.parent = to
    child.matrix_parent_inverse = to.matrix_world.inverted()


def jointed_hand(prefix, heel, *, thumb_side, finger_offset=0.0):
    """One hand palm down at rest, its pieces under one empty at the heel. Returns the empty and,
    per finger, its three phalanges from the knuckle out."""
    bpy.ops.object.empty_add(location=g.blender(heel))
    root = bpy.context.active_object
    root.name = prefix + "_root"

    hx, hy, hz = heel
    palm_y = hy + 0.013
    palm = g.Body(prefix + "_palm", resolution=0.0022)
    palm.segment((hx, palm_y, hz - 0.006), (hx, palm_y + 0.002, hz - 0.078), across=0.041, depth=0.012, overlap=0.006)
    palm.capsule((hx + 0.029, palm_y + 0.001, hz - 0.082), (hx - 0.029, palm_y + 0.001, hz - 0.082), 0.0095)
    palm.ellipsoid((hx + 0.022 * thumb_side, palm_y - 0.002, hz - 0.028), (0.016, 0.012, 0.03))
    palm.ellipsoid((hx - 0.018 * thumb_side, palm_y - 0.002, hz - 0.02), (0.016, 0.011, 0.024))
    palm.ellipsoid((hx, palm_y - 0.003, hz - 0.01), (0.03, 0.011, 0.016))
    rigid = [palm.mesh()]
    base = (hx + 0.036 * thumb_side, palm_y - 0.002, hz - 0.022)
    points, _ = g.finger_points(base, (0.3 * thumb_side, -0.05, -1), 0.062, 0.1)
    rigid.append(g.tube(prefix + "_thumb", *g.jointed(points[:3], [0.0128, 0.0118, 0.0098])))
    rigid.append(g.tube(prefix + "_wrist", [(hx, palm_y - 0.001, hz - 0.012), (hx, palm_y + 0.003, hz + 0.022)], [0.019, 0.021]))
    for piece in rigid:
        parent(piece, root)

    fingers = []
    knuckle_y = palm_y + 0.004
    for i, (length, across) in enumerate(g.FINGERS):
        joint = Vector((hx + across * thumb_side + finger_offset, knuckle_y, hz - 0.088))
        previous = root
        bones = []
        radii = [g.FINGER_RADIUS * g.FINGER_THICKNESS[i] * f for f in (1.08, 1.0, 0.93, 0.8)]
        heading = Vector((across / 0.029 * g.FAN * thumb_side, 0, -1)).normalized()
        for k, share in enumerate(g.PHALANGES):
            end = joint + heading * length * share
            # A little past the next joint, so the bend is covered when it curls, and slimmer between
            # joints than at them, so the knuckles read.
            past = end + heading * 0.002
            bone = g.tube(
                f"{prefix}_f{i}_{k}",
                [tuple(joint), tuple(joint.lerp(past, 0.5)), tuple(past)],
                [radii[k], min(radii[k], radii[k + 1]) * 0.95, radii[k + 1]],
            )
            pivot(bone, tuple(joint))
            parent(bone, previous)
            bones.append(bone)
            previous, joint = bone, end
        fingers.append(bones)
    return root, fingers


def mano_hand(name, data, side):
    """A MANO hand that closes into the grip: its first pose as the mesh, every later one a shape key."""
    frames = data[f"{side}_frames"]
    obj = g.mano_mesh(name, frames[0], data[f"{side}_faces"], shapes=frames[1:])
    bpy.ops.object.empty_add(location=(0, 0, 0))
    root = bpy.context.active_object
    root.name = name + "_root"
    parent(obj, root)
    return root, obj


def close(obj, start, end):
    """Steps through the shape keys from `start` to `end`, each fading in as the last fades out."""
    keys = obj.data.shape_keys.key_blocks[1:]
    span = (end - start) / max(1, len(keys))
    for i, key in enumerate(keys):
        at = start + (i + 1) * span
        for frame, value in ((at - span, 0.0), (at, 1.0), (at + span, 0.0)):
            if i == len(keys) - 1 and frame > at:
                continue
            key.value = value
            key.keyframe_insert("value", frame=frame)
    # Each key is relative to the open hand, so only one is on at a time; the last stays on.


def curl(fingers, angle, frame, *, first_only=False):
    """Keys every phalanx bent `angle` radians down toward the palm, or the knuckle joint up for a lift."""
    for bones in fingers:
        for k, bone in enumerate(bones):
            # Model x is Blender x; turning about it by a negative angle bends a finger down.
            bone.rotation_euler.x = -angle if (k == 0 or not first_only) else 0.0
            bone.keyframe_insert("rotation_euler", index=0, frame=frame)


def move(obj, offset, frame):
    obj.location = Vector(g.blender(offset)) + Vector(obj["rest"])
    obj.keyframe_insert("location", frame=frame)


# --- Materials -----------------------------------------------------------------------------------


def glass():
    m = bpy.data.materials.new("glass")
    m.use_nodes = True
    nodes, links = m.node_tree.nodes, m.node_tree.links
    bsdf = nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (0.12, 0.42, 1.0, 1)
    bsdf.inputs["Roughness"].default_value = 0.15
    # More solid than the app's, so a jointed finger's segments don't show through one another.
    bsdf.inputs["Alpha"].default_value = 0.85
    bsdf.inputs["Coat Weight"].default_value = 1.0
    rim = nodes.new("ShaderNodeLayerWeight")
    rim.inputs["Blend"].default_value = 0.45
    links.new(rim.outputs["Facing"], bsdf.inputs["Emission Strength"])
    bsdf.inputs["Emission Color"].default_value = (0.35, 0.7, 1.0, 1)
    m.surface_render_method = "BLENDED"
    m.use_backface_culling = True
    return m


def flat(name, color, roughness=0.7, emission=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*color, 1)
    b.inputs["Roughness"].default_value = roughness
    if emission:
        b.inputs["Emission Color"].default_value = (*color, 1)
        b.inputs["Emission Strength"].default_value = emission
    return m


def assign(obj, material):
    if obj.type == "MESH":
        obj.data.materials.clear()
        obj.data.materials.append(material)
    for child in obj.children:
        assign(child, material)


# --- Scene ---------------------------------------------------------------------------------------


def chest_gives(patient):
    """A shape key that presses the chest in under the hands, falling off across the ribs, so a push
    moves the chest and the hands don't sink through it."""
    patient.shape_key_add(name="Basis")
    key = patient.shape_key_add(name="Pressed")
    centre = Vector(g.blender((0, 0, -0.04)))
    for vertex in key.data:
        offset = vertex.co - centre
        # Only the front of the chest, where it faces up.
        if vertex.co.z < centre.z - 0.06:
            continue
        reach = math.hypot(offset.x / 0.16, offset.y / 0.14)
        if reach < 1:
            vertex.co.z -= DEPTH * (0.5 + 0.5 * math.cos(math.pi * reach))
    return key


# Captions sit this close to the lens, in front of everything in the scene, and scale with it.
CARD = 0.12


def caption_cards(camera):
    """Each caption as white text on a dark band at the bottom of the frame, shown for its span."""
    band_mat = flat("band", (0.02, 0.03, 0.06), emission=0.0)
    band_mat.node_tree.nodes["Principled BSDF"].inputs["Alpha"].default_value = 0.72
    band_mat.surface_render_method = "BLENDED"
    text_mat = flat("text", (1, 1, 1), emission=1.5)
    for start, end, words in CAPTIONS:
        bpy.ops.object.text_add()
        text = bpy.context.active_object
        text.data.body = words
        text.data.align_x = "CENTER"
        text.data.align_y = "CENTER"
        text.data.size = 0.03 * CARD
        text.data.space_line = 0.9
        # Wrap to the frame's width.
        text.data.text_boxes[0].width = 0.62 * CARD
        text.data.text_boxes[0].x = -0.31 * CARD
        text.data.materials.append(text_mat)
        text.parent = camera
        text.location = (0, -0.3 * CARD, -CARD)
        bpy.ops.mesh.primitive_plane_add(size=1)
        band = bpy.context.active_object
        band.scale = (0.8 * CARD, 0.11 * CARD, 1)
        band.data.materials.append(band_mat)
        band.parent = camera
        band.location = (0, -0.3 * CARD, -CARD * 1.001)
        for obj in (text, band):
            for frame, hidden in ((0, True), (start, False), (end, True)):
                obj.hide_render = hidden
                obj.keyframe_insert("hide_render", frame=frame)


def main():
    g.clear_scene()
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = scene.render.resolution_y = 480 if CLIP else 1080
    scene.render.fps = FPS
    scene.frame_start, scene.frame_end = 0, (CLIP_FRAMES - 1 if CLIP else LAST_FRAME)
    scene.view_settings.view_transform = "Standard"
    scene.eevee.taa_render_samples = 24

    patient = g.patient()
    assign(patient, flat("skin", (0.45, 0.29, 0.21), 0.6))
    chest_gives(patient)
    bpy.ops.mesh.primitive_plane_add(size=6, location=(0, 0, -0.2))
    assign(bpy.context.active_object, flat("floor", (0.52, 0.38, 0.24), 0.8))

    # The target, on the lower half of the breastbone.
    bpy.ops.mesh.primitive_torus_add(major_radius=0.06, minor_radius=0.0025, location=g.blender((0, 0.016, -0.04)))
    ring = bpy.context.active_object
    assign(ring, flat("ring", (0.2, 0.9, 1.0), 0.3, emission=3))
    bpy.ops.mesh.primitive_torus_add(major_radius=0.085, minor_radius=0.002, location=g.blender((0, 0.016, -0.04)))
    outer = bpy.context.active_object
    assign(outer, flat("ring2", (1, 1, 1), 0.3, emission=2))
    # The target shows where the heel goes, then gets out of the way of the grip.
    for obj in (ring, outer):
        for frame, size in ((0, 1.0), (10, 1.0), (16, 0.01)):
            obj.scale = (size, size, size)
            obj.keyframe_insert("scale", frame=frame)

    glass_mat = glass()
    mano = None
    if g.MANO_HANDS:
        import numpy as np

        mano = np.load(g.MANO_HANDS)
        lower, lower_mesh = mano_hand("HandLower", mano, "lower")
        upper, upper_mesh = mano_hand("HandUpper", mano, "upper")
    else:
        lower, lower_fingers = jointed_hand("lower", (0.0, 0.0, 0.0), thumb_side=1)
        upper, upper_fingers = jointed_hand("upper", (0.0, 0.026, 0.012), thumb_side=-1, finger_offset=0.0095)
    for root in (lower, upper):
        assign(root, glass_mat)
        root["rest"] = root.location.copy()

    # Straight to the grip: the lower hand is already down, the upper one drops onto it at once.
    move(lower, (0, 0, 0), 0)
    # In from the rescuer's side and down onto the lower hand, so that one is seen alone first.
    move(upper, (0, 0.08, 0.07), 0)
    move(upper, (0, 0.08, 0.07), 6)
    move(upper, (0, 0, 0), 20)
    # Then the cup: the top fingers curl down and lace, the bottom ones lift off the chest.
    if mano is not None:
        close(upper_mesh, 16, 38)
        close(lower_mesh, 20, 40)
    else:
        curl(upper_fingers, 0.0, 0)
        curl(upper_fingers, 0.0, 16)
        curl(upper_fingers, 0.38, 38)
        curl(lower_fingers, 0.0, 0)
        curl(lower_fingers, 0.0, 22)
        curl(lower_fingers, -0.14, 40, first_only=True)

    # Compressions: fast down, full recoil, on the beat.
    start = 70
    cycles = int((LAST_FRAME - start) / BEAT)
    pressed = patient.data.shape_keys.key_blocks["Pressed"]
    pressed.value = 0
    pressed.keyframe_insert("value", frame=start)
    for root in (lower, upper):
        move(root, (0, 0, 0), start)
    for n in range(cycles):
        t = start + n * BEAT
        down, up = round(t + BEAT * 0.4), round(t + BEAT)
        for root in (lower, upper):
            move(root, (0, -DEPTH, 0), down)
            move(root, (0, 0, 0), up)
        for frame, value in ((down, 1.0), (up, 0.0)):
            pressed.value = value
            pressed.keyframe_insert("value", frame=frame)
    for obj in (lower, upper):
        for curve in obj.animation_data.action.fcurves if obj.animation_data.action and hasattr(obj.animation_data.action, "fcurves") else []:
            for key in curve.keyframe_points:
                key.interpolation = "SINE"

    # Top down, as the rescuer sees their own hands: the rescuer at the bottom of the frame, fingers
    # pointing up it, tipped 12 degrees toward the rescuer so the fingers' curl down still shows.
    camera_data = bpy.data.cameras.new("camera")
    camera_data.lens = 40
    camera_data.clip_start = 0.01
    camera = bpy.data.objects.new("camera", camera_data)
    bpy.context.collection.objects.link(camera)
    scene.camera = camera
    tilt = math.radians(12)
    # A corner card is small, so the clip sits closer in on the hands.
    heights = ((0, 0.32), (LAST_FRAME, 0.32)) if CLIP else ((0, 0.34), (60, 0.35), (LAST_FRAME, 0.4))
    for frame, height in heights:
        # Model +z is toward the rescuer; the camera sits back that way by its tilt and looks at the grip.
        camera.location = Vector(g.blender((0, height, (-0.01 if CLIP else -0.03) + height * math.tan(tilt))))
        camera.rotation_euler = (tilt, 0, 0)
        camera.keyframe_insert("location", frame=frame)
        camera.keyframe_insert("rotation_euler", frame=frame)
    if not CLIP:
        caption_cards(camera)

    bpy.ops.object.light_add(type="SUN", location=(0.5, 0.5, 2), rotation=(0.6, 0.3, 0.4))
    bpy.context.active_object.data.energy = 2.2
    world = bpy.data.worlds.new("world")
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.6, 0.62, 0.68, 1)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.45

    if "--stills" in sys.argv:
        # A frame from each stage, to check the scene before a full render.
        for frame in (2, 12, 24, 40, 76):
            scene.frame_set(frame)
            scene.render.filepath = os.path.join(os.path.dirname(OUT), f"cpr_frame_{frame:03d}.png")
            bpy.ops.render.render(write_still=True)
        return

    if CLIP:
        # The finished grip as a still, for Reduce Motion.
        scene.frame_set(CLIP_FRAMES - 1)
        scene.render.filepath = OUT.replace(".mp4", ".png")
        bpy.ops.render.render(write_still=True)
        scene.frame_set(0)

    scene.render.image_settings.media_type = "VIDEO" if hasattr(scene.render.image_settings, "media_type") else scene.render.image_settings.file_format
    scene.render.image_settings.file_format = "FFMPEG"
    scene.render.ffmpeg.format = "MPEG4"
    scene.render.ffmpeg.codec = "H264"
    scene.render.ffmpeg.constant_rate_factor = "HIGH"
    scene.render.filepath = OUT
    bpy.ops.render.render(animation=True)
    print(f"[video] wrote {OUT}")


if __name__ == "__main__":
    main()
