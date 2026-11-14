"""Builds the ghost rescuer and practice patient as smooth mannequins and exports them as USDZ.

Run with Blender, headless:

    blender -b --python tools/make_ghost_model.py

It writes Packages/RescueVision/Sources/RescueVision/Resources/Ghost.usdz with these meshes:

- RescuerUpper: torso from the waist up, arms, hands and head. The app moves it down 5 cm on each
  push, so its waist runs down inside RescuerLower and no gap opens.
- RescuerLower: pelvis and kneeling legs, which stay still.
- Patient: an adult lying face up, filled in for practice.
- PatientOutline: the same body grown 1.5 cm along its normals. The app draws only its back faces,
  which leaves a clean edge around the body, so a real dummy shows through with a line traced round it.

Model space, in metres, after export (Y up): +x toward the patient's head, +y up, +z toward the
side the rescuer kneels on. The origin is the top of the patient's chest, where the hands go, and
the floor is at y = -0.2. These match GhostRescuer and PracticePatient in RescueVision.

It also writes Hands.usdz there, HandLower and HandUpper, each fused into one closed skin so it can
be drawn see-through: two adult hands stacked for compressions, the lower one's heel on
the sternum and the upper one's fingers laced down between its fingers, which lift off the chest.
Hand space: heel of the lower hand at the origin on the chest, +y up off the chest, fingers along -z,
away from the rescuer, who kneels toward +z. The app turns it to the rescuer's side.

Every shape is a metaball made here from numbers, so the model needs no third-party asset or licence.
"""

import os

import bpy
from mathutils import Matrix, Vector

RESOURCES = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "Packages", "RescueVision", "Sources", "RescueVision", "Resources",
)
OUT = os.path.join(RESOURCES, "Ghost.usdz")
HANDS_OUT = os.path.join(RESOURCES, "Hands.usdz")


def blender(p):
    """Model space (x head, y up, z side) to Blender's Z-up axes, which the exporter turns back to Y up."""
    x, y, z = p
    return (x, -z, y)


def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    for mesh in list(bpy.data.meshes):
        bpy.data.meshes.remove(mesh)
    for ball in list(bpy.data.metaballs):
        bpy.data.metaballs.remove(ball)


# Metaballs melt into one another where they meet, so shoulders, neck and hips blend the way a body
# does instead of meeting as tubes. Each part is one metaball object, converted to a mesh.
RESOLUTION = 0.014
# Influence radius to visible radius, measured on one capsule at the default threshold of 0.6.
VISIBLE = 0.62


class Body:
    def __init__(self, name, resolution=RESOLUTION):
        self.name = name
        self.data = bpy.data.metaballs.new(name)
        self.data.resolution = resolution
        self.data.render_resolution = resolution
        self.obj = bpy.data.objects.new(name, self.data)
        bpy.context.collection.objects.link(self.obj)

    def capsule(self, a, b, radius):
        """A limb from a to b, `radius` thick as seen."""
        a, b = Vector(blender(a)), Vector(blender(b))
        element = self.data.elements.new(type="CAPSULE")
        element.co = (a + b) / 2
        element.radius = radius / VISIBLE
        element.size_x = (b - a).length / 2
        element.rotation = Vector((1, 0, 0)).rotation_difference((b - a).normalized())
        return element

    def ellipsoid(self, center, size, toward=None):
        """`size` is half the width along model x, y and z, or along `toward` first when given."""
        element = self.data.elements.new(type="ELLIPSOID")
        element.co = Vector(blender(center))
        element.radius = max(size) / VISIBLE
        sx, sy, sz = (s / max(size) for s in size)
        element.size_x, element.size_y, element.size_z = sx, sz, sy
        if toward is not None:
            element.rotation = Vector((1, 0, 0)).rotation_difference(Vector(blender(toward)).normalized())
        return element

    def segment(self, a, b, across, depth, overlap=0.04):
        """A flattened volume from a to b: `across` half-wide toward the patient's head, `depth` half-deep."""
        a, b = Vector(blender(a)), Vector(blender(b))
        along = (b - a).normalized()
        wide = Vector(blender((1, 0, 0)))
        wide = (wide - wide.dot(along) * along).normalized()
        deep = along.cross(wide)
        half = (b - a).length / 2 + overlap
        element = self.data.elements.new(type="ELLIPSOID")
        element.co = (a + b) / 2
        biggest = max(half, across, depth)
        element.radius = biggest / VISIBLE
        element.size_x, element.size_y, element.size_z = half / biggest, across / biggest, depth / biggest
        basis = Matrix((along, wide, deep)).transposed()
        element.rotation = basis.to_quaternion()
        return element

    def mesh(self):
        bpy.ops.object.select_all(action="DESELECT")
        bpy.context.view_layer.objects.active = self.obj
        self.obj.select_set(True)
        bpy.ops.object.convert(target="MESH")
        obj = bpy.context.active_object
        for leftover in [o for o in bpy.data.objects if o.type == "META" and o.data == self.data]:
            bpy.data.objects.remove(leftover)
        obj.name = self.name
        obj.data.name = self.name + "Mesh"
        bpy.ops.object.shade_smooth()
        obj.select_set(False)
        return obj


# --- The rescuer, kneeling on the far side with locked arms, shoulders over the hands -----------------

FLOOR = -0.2
SHOULDER_Y = 0.59


def rescuer_upper():
    body = Body("RescuerUpper")
    # The torso leans in from the hips to over the hands, wider across than deep. Its waist runs down
    # inside the pelvis, so the 5 cm the app moves it on a push never opens a gap.
    waist = (0.0, 0.27, 0.43)
    ribs = (0.0, 0.45, 0.22)
    shoulders = (0.0, SHOULDER_Y, 0.05)
    body.segment(waist, ribs, across=0.135, depth=0.105)
    body.segment(ribs, shoulders, across=0.16, depth=0.12, overlap=0.02)
    body.capsule((0.13, SHOULDER_Y - 0.02, 0.06), (-0.13, SHOULDER_Y - 0.02, 0.06), 0.055)
    # Neck and head, bowed forward over the hands.
    body.capsule((0.0, SHOULDER_Y + 0.01, 0.06), (0.0, 0.67, -0.02), 0.048)
    body.ellipsoid((0.0, 0.73, -0.06), (0.078, 0.092, 0.09))
    for x in (1, -1):
        shoulder = (0.18 * x, SHOULDER_Y - 0.03, 0.05)
        elbow = (0.11 * x, 0.33, 0.025)
        wrist = (0.035 * x, 0.075, 0.02)
        body.ellipsoid(shoulder, (0.055, 0.058, 0.055))
        body.capsule(shoulder, elbow, 0.05)
        body.capsule(elbow, wrist, 0.038)
    # Both hands stacked, heel on the chest, fingers interlaced.
    body.ellipsoid((0.0, 0.035, -0.01), (0.048, 0.035, 0.08))
    return body.mesh()


def rescuer_lower():
    body = Body("RescuerLower")
    body.ellipsoid((0.0, 0.28, 0.45), (0.15, 0.1, 0.11))
    for x in (1, -1):
        hip = (0.09 * x, 0.25, 0.45)
        knee = (0.12 * x, FLOOR + 0.06, 0.30)
        ankle = (0.12 * x, FLOOR + 0.05, 0.72)
        body.capsule(hip, knee, 0.075)
        body.capsule(knee, ankle, 0.05)
        body.ellipsoid((0.12 * x, FLOOR + 0.04, 0.8), (0.045, 0.035, 0.1))
    return body.mesh()


# --- The patient, face up, chest top at the origin ---------------------------------------------------

BODY = FLOOR + 0.1


def patient():
    body = Body("Patient")
    body.capsule((-0.36, BODY, 0.0), (0.1, BODY, 0.0), 0.11)
    body.ellipsoid((0.05, BODY, 0.0), (0.14, 0.095, 0.17))
    body.ellipsoid((-0.4, BODY, 0.0), (0.12, 0.09, 0.16))
    body.capsule((0.17, BODY, 0.17), (0.17, BODY, -0.17), 0.07)
    body.capsule((0.2, BODY, 0.0), (0.32, BODY, 0.0), 0.05)
    body.ellipsoid((0.42, BODY + 0.01, 0.0), (0.1, 0.08, 0.075))
    for z in (1, -1):
        shoulder = (0.16, BODY, 0.2 * z)
        elbow = (-0.1, BODY - 0.02, 0.25 * z)
        wrist = (-0.35, BODY - 0.03, 0.27 * z)
        body.capsule(shoulder, elbow, 0.047)
        body.capsule(elbow, wrist, 0.037)
        body.ellipsoid((-0.43, BODY - 0.04, 0.28 * z), (0.07, 0.02, 0.04))
        hip = (-0.42, BODY, 0.1 * z)
        knee = (-0.84, BODY - 0.02, 0.12 * z)
        ankle = (-1.25, BODY - 0.05, 0.13 * z)
        body.capsule(hip, knee, 0.075)
        body.capsule(knee, ankle, 0.05)
        body.ellipsoid((-1.29, BODY - 0.01, 0.13 * z), (0.04, 0.085, 0.045))
    return body.mesh()


OUTLINE = 0.015


def outline(body):
    """A copy grown along its normals, for an inverted-hull outline."""
    shell = body.copy()
    shell.data = body.data.copy()
    shell.name = "PatientOutline"
    shell.data.name = "PatientOutlineMesh"
    bpy.context.collection.objects.link(shell)
    for vertex in shell.data.vertices:
        vertex.co += vertex.normal * OUTLINE
    return shell


# --- The hands, stacked on the sternum -------------------------------------------------------------
#
# Built from separate smooth pieces rather than metaballs, so fingers stay apart instead of melting
# into one another and each hand keeps its own edge. Each hand also gets a dark outline shell.

# Finger lengths in metres, index to little, how far each sits across the knuckles from the middle,
# and how thick each is against the middle finger.
FINGERS = [(0.074, 0.029), (0.081, 0.0095), (0.076, -0.0095), (0.061, -0.028)]
FINGER_THICKNESS = [1.0, 1.03, 0.97, 0.86]
# Fingers fan out a little from the knuckles, as a relaxed hand's do.
FAN = 0.07
PHALANGES = (0.47, 0.3, 0.23)
FINGER_RADIUS = 0.0088
HAND_OUTLINE = 0.0022
# The Skin modifier's tube comes out about this much thinner once subdivided.
SKIN_SHRINK = 0.86


def apply_modifiers(obj):
    bpy.ops.object.select_all(action="DESELECT")
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    for modifier in list(obj.modifiers):
        bpy.ops.object.modifier_apply(modifier=modifier.name)
    obj.select_set(False)


def tube(name, points, radii):
    """A smooth tube through `points`, model space, rounded at both ends."""
    mesh = bpy.data.meshes.new(name)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    mesh.from_pydata([blender(p) for p in points], [(i, i + 1) for i in range(len(points) - 1)], [])
    obj.modifiers.new("Skin", "SKIN").use_smooth_shade = True
    layer = mesh.skin_vertices[""].data
    for i, r in enumerate(radii):
        layer[i].radius = (r / SKIN_SHRINK, r / SKIN_SHRINK)
    layer[0].use_root = True
    obj.modifiers.new("Subdivision", "SUBSURF").levels = 2
    apply_modifiers(obj)
    return obj


def rounded_box(name, center, size, bevel, taper=1.0):
    """A slab with soft edges. `size` is the full width along model x, y and z. `taper` narrows its
    +z end, toward the wrist, to that share of its width."""
    bpy.ops.mesh.primitive_cube_add(size=1, location=blender(center))
    obj = bpy.context.active_object
    obj.name = name
    sx, sy, sz = size
    obj.scale = (sx, sz, sy)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if taper != 1.0:
        # Model +z is Blender -y.
        for vertex in obj.data.vertices:
            if vertex.co.y < 0:
                vertex.co.x *= taper
    b = obj.modifiers.new("Bevel", "BEVEL")
    b.width = bevel
    b.segments = 4
    obj.modifiers.new("Subdivision", "SUBSURF").levels = 2
    apply_modifiers(obj)
    bpy.ops.object.shade_smooth()
    return obj


def finger_points(knuckle, direction, length, curl):
    """The knuckle and each joint after it, each bending `curl` radians further toward the palm."""
    point = Vector(knuckle)
    heading = Vector(direction).normalized()
    side = heading.cross(Vector((0, 1, 0))).normalized()
    points = [tuple(point)]
    for share in PHALANGES:
        heading = Matrix.Rotation(-curl, 3, side) @ heading
        point = point + heading * length * share
        points.append(tuple(point))
    return points, heading


def jointed(points, radii):
    """Each phalanx slimmer between its joints than at them, so the knuckles read."""
    out_points, out_radii = [points[0]], [radii[0]]
    for i in range(1, len(points)):
        a, b = Vector(points[i - 1]), Vector(points[i])
        out_points += [tuple(a.lerp(b, 0.5)), points[i]]
        out_radii += [min(radii[i - 1], radii[i]) * 0.95, radii[i]]
    return out_points, out_radii


def nail(tip, heading, radius):
    """A flat oval on the back of the fingertip."""
    up = Vector((0, 1, 0))
    back = (up - up.dot(heading) * heading).normalized()
    center = Vector(tip) - heading * radius * 1.35 + back * radius * 0.86
    bpy.ops.mesh.primitive_uv_sphere_add(segments=16, ring_count=8, radius=1, location=blender(tuple(center)))
    obj = bpy.context.active_object
    obj.scale = (radius * 0.68, radius * 0.95, radius * 0.16)
    # Lay it along the finger: Blender's local y to the finger's heading, local z to its back.
    h, b = Vector(blender(tuple(heading))), Vector(blender(tuple(back)))
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = Matrix((h.cross(b), h, b)).transposed().to_quaternion()
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    bpy.ops.object.shade_smooth()
    return obj


def hand(prefix, heel, *, lift, thumb_side, curl, finger_offset=0.0, finger_pitch=0.0):
    """One hand palm down, heel at `heel`. Returns its skin pieces and its nails."""
    hx, hy, hz = heel
    palm_y = hy + 0.013
    # The palm from soft volumes, so it domes and narrows to the wrist the way a hand does.
    palm = Body(prefix + "_palm", resolution=0.0022)
    palm.segment((hx, palm_y, hz - 0.006), (hx, palm_y + 0.002, hz - 0.078), across=0.041, depth=0.012, overlap=0.006)
    palm.capsule((hx + 0.029, palm_y + 0.001, hz - 0.082), (hx - 0.029, palm_y + 0.001, hz - 0.082), 0.0095)
    palm.ellipsoid((hx + 0.022 * thumb_side, palm_y - 0.002, hz - 0.028), (0.016, 0.012, 0.03))
    palm.ellipsoid((hx - 0.018 * thumb_side, palm_y - 0.002, hz - 0.02), (0.016, 0.011, 0.024))
    palm.ellipsoid((hx, palm_y - 0.003, hz - 0.01), (0.03, 0.011, 0.016))
    pieces = [palm.mesh()]
    nails = []
    knuckle_y = palm_y + 0.004 + lift
    for i, (length, across) in enumerate(FINGERS):
        knuckle = (hx + across * thumb_side + finger_offset, knuckle_y, hz - 0.088)
        fan = across / 0.029 * FAN * thumb_side
        points, heading = finger_points(knuckle, (fan, finger_pitch, -1), length, curl)
        radii = [FINGER_RADIUS * FINGER_THICKNESS[i] * f for f in (1.08, 1.0, 0.93, 0.8)]
        pieces.append(tube(f"{prefix}_finger{i}", *jointed(points, radii)))
        nails.append(nail(points[-1], heading, radii[-1]))
    # The thumb, from the side of the palm toward the fingers, tucked along the hand.
    base = (hx + 0.036 * thumb_side, palm_y - 0.002, hz - 0.022)
    points, heading = finger_points(base, (0.3 * thumb_side, -0.05, -1), 0.062, 0.1)
    pieces.append(tube(prefix + "_thumb", *jointed(points[:3], [0.0128, 0.0118, 0.0098])))
    nails.append(nail(points[2], (Vector(points[2]) - Vector(points[1])).normalized(), 0.0098))
    # A short cuff of wrist, so the hand doesn't stop at a hard edge.
    # Starts inside the palm, so it grows out of it rather than sitting beside it.
    pieces.append(tube(prefix + "_wrist", [(hx, palm_y - 0.001, hz - 0.012), (hx, palm_y + 0.003, hz + 0.022)], [0.019, 0.021]))
    return pieces, nails


def outline_shell(name, obj):
    """The hand grown a little and turned inside out: drawn with back faces culled, only its rim
    outside the hand shows, as a line round it."""
    shell = obj.copy()
    shell.data = obj.data.copy()
    shell.name = name
    shell.data.name = name + "Mesh"
    bpy.context.collection.objects.link(shell)
    for vertex in shell.data.vertices:
        vertex.co += vertex.normal * HAND_OUTLINE
    shell.data.flip_normals()
    return shell


# Voxel size for fusing a hand's pieces into one watertight skin. Fine enough to keep the gaps
# between fingers; a see-through hand made of overlapping pieces would show every piece inside it.
FUSE_VOXEL = 0.0007
HAND_FACES = 16000


def fuse(obj):
    """One closed surface from overlapping pieces, smoothed and thinned to a phone's budget."""
    remesh = obj.modifiers.new("Remesh", "REMESH")
    remesh.mode = "VOXEL"
    remesh.voxel_size = FUSE_VOXEL
    remesh.adaptivity = 0.0
    smooth = obj.modifiers.new("Smooth", "SMOOTH")
    smooth.factor = 0.6
    smooth.iterations = 4
    apply_modifiers(obj)
    faces = len(obj.data.polygons)
    if faces > HAND_FACES:
        decimate = obj.modifiers.new("Decimate", "DECIMATE")
        decimate.ratio = HAND_FACES / faces
        apply_modifiers(obj)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.shade_smooth()
    obj.select_set(False)
    return obj


# Real hands from MANO, posed by tools/make_mano_hands.py, when its output is given. Without it the
# hands are built here from shapes, as before.
MANO_HANDS = os.environ.get("MANO_HANDS")


def mano_mesh(name, vertices, faces, shapes=()):
    """A MANO hand, smoothed one level, with each later pose as a shape key on it."""
    mesh = bpy.data.meshes.new(name + "Mesh")
    mesh.from_pydata([blender(tuple(v)) for v in vertices], [], [tuple(f) for f in faces])
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    if len(shapes):
        obj.shape_key_add(name="Basis")
        for i, step in enumerate(shapes):
            key = obj.shape_key_add(name=f"step{i}")
            for vertex, point in zip(key.data, step):
                vertex.co = blender(tuple(point))
    sub = obj.modifiers.new("Subdivision", "SUBSURF")
    sub.levels = sub.render_levels = 1
    if not len(shapes):
        apply_modifiers(obj)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.shade_smooth()
    obj.select_set(False)
    return obj


def mano_hands(path):
    import numpy as np

    data = np.load(path)
    return [
        mano_mesh("HandLower", data["lower_frames"][-1], data["lower_faces"]),
        mano_mesh("HandUpper", data["upper_frames"][-1], data["upper_faces"]),
    ]


def hands():
    """The lower hand's heel on the chest, fingers straight and lifted. The upper hand on its back,
    fingers laced down into the gaps between the lower hand's."""
    if MANO_HANDS:
        return mano_hands(MANO_HANDS)
    lower_pieces, lower_nails = hand("lower", (0.0, 0.0, 0.0), lift=0.004, thumb_side=1, curl=0.05, finger_pitch=0.09)
    upper_pieces, upper_nails = hand(
        "upper", (0.0, 0.026, 0.012), lift=0.0, thumb_side=-1, curl=0.36, finger_offset=0.0095
    )
    # Each hand one skin, its nails pressed into it as the slight ridges they are.
    lower = fuse(join("HandLower", lower_pieces + lower_nails))
    upper = fuse(join("HandUpper", upper_pieces + upper_nails))
    # No outline shells: the hands are see-through, and a shell's inside would show through them as
    # scratches. Their edge comes from the glassy material's rim instead.
    return [lower, upper]


def join(name, objects):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    bpy.ops.object.join()
    joined = bpy.context.active_object
    joined.name = name
    joined.data.name = name + "Mesh"
    joined.select_set(False)
    return joined


def export(path, objects):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.wm.usd_export(
        filepath=os.path.abspath(path),
        selected_objects_only=True,
        export_materials=False,
        export_animation=False,
        convert_orientation=True,
        export_global_forward_selection="NEGATIVE_Z",
        export_global_up_selection="Y",
        triangulate_meshes=True,
    )
    print(f"[ghost] wrote {os.path.abspath(path)}")


def main():
    clear_scene()
    body = patient()
    parts = [rescuer_upper(), rescuer_lower(), body, outline(body)]
    for obj in parts:
        print(f"[ghost] {obj.name}: {len(obj.data.vertices)} vertices")
    export(OUT, parts)

    stacked = hands()
    for obj in stacked:
        print(f"[ghost] {obj.name}: {len(obj.data.vertices)} vertices")
    export(HANDS_OUT, stacked)


if __name__ == "__main__":
    main()
