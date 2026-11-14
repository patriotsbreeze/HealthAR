"""Builds the ghost rescuer and practice patient as smooth mannequins and exports them as USDZ.

Run with Blender, headless:

    blender -b --python tools/make_ghost_model.py

It writes Packages/RescueVision/Sources/RescueVision/Resources/Ghost.usdz with three meshes:

- RescuerUpper: torso from the waist up, arms, hands and head. The app moves it down 5 cm on each
  push, so its waist runs down inside RescuerLower and no gap opens.
- RescuerLower: pelvis and kneeling legs, which stay still.
- Patient: an adult lying face up, filled in for practice.
- PatientOutline: the same body grown 1.5 cm along its normals. The app draws only its back faces,
  which leaves a clean edge around the body, so a real dummy shows through with a line traced round it.

Model space, in metres, after export (Y up): +x toward the patient's head, +y up, +z toward the
side the rescuer kneels on. The origin is the top of the patient's chest, where the hands go, and
the floor is at y = -0.2. These match GhostRescuer and PracticePatient in RescueVision.

Every shape is a metaball made here from numbers, so the model needs no third-party asset or licence.
"""

import os

import bpy
from mathutils import Matrix, Vector

OUT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "Packages", "RescueVision", "Sources", "RescueVision", "Resources", "Ghost.usdz",
)


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
    def __init__(self, name):
        self.name = name
        self.data = bpy.data.metaballs.new(name)
        self.data.resolution = RESOLUTION
        self.data.render_resolution = RESOLUTION
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


def main():
    clear_scene()
    body = patient()
    parts = [rescuer_upper(), rescuer_lower(), body, outline(body)]
    for obj in parts:
        print(f"[ghost] {obj.name}: {len(obj.data.vertices)} vertices")

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    bpy.ops.wm.usd_export(
        filepath=os.path.abspath(OUT),
        export_materials=False,
        export_animation=False,
        convert_orientation=True,
        export_global_forward_selection="NEGATIVE_Z",
        export_global_up_selection="Y",
        triangulate_meshes=True,
    )
    print(f"[ghost] wrote {os.path.abspath(OUT)}")


main()
