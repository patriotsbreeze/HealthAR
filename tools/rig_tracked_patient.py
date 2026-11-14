"""Rig the existing smooth tracked patient without changing the practice animation.

Requires Python with usd-core. Run: python tools/rig_tracked_patient.py
Bakes the Blender root conversion into vertices, then adds a 13-joint skin to the
original body and outline. No spheres or replacement geometry are generated.
"""
import argparse
import math
from pathlib import Path
import tempfile
from pxr import Gf, Sdf, Usd, UsdGeom, UsdSkel, UsdUtils, Vt

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Packages/RescueVision/Sources/RescueVision/Resources"
# Bind positions match patient() in make_ghost_model.py after the root's Y-up conversion.
JOINTS = [("root", (0, 0, 0), -1)]
for side, sign in (("positive", 1), ("negative", -1)):
    parent = len(JOINTS)
    JOINTS += [
        (f"root/{side}Shoulder", (0.16, -0.1, 0.2 * sign), 0),
        (f"root/{side}Shoulder/elbow", (-0.1, -0.12, 0.25 * sign), parent),
        (f"root/{side}Shoulder/elbow/wrist", (-0.35, -0.13, 0.27 * sign), parent + 1),
    ]
for side, sign in (("positive", 1), ("negative", -1)):
    parent = len(JOINTS)
    JOINTS += [
        (f"root/{side}Hip", (-0.42, -0.1, 0.1 * sign), 0),
        (f"root/{side}Hip/knee", (-0.84, -0.12, 0.12 * sign), parent),
        (f"root/{side}Hip/knee/ankle", (-1.25, -0.15, 0.13 * sign), parent + 1),
    ]


def distance(point, a, b):
    ab = b - a
    t = max(0, min(1, Gf.Dot(point - a, ab) / max(1e-9, Gf.Dot(ab, ab))))
    return (point - (a + t * ab)).GetLength()


def skin_weights(points):
    positions = [Gf.Vec3d(*position) for _, position, _ in JOINTS]
    children = {parent: i for i, (_, _, parent) in enumerate(JOINTS) if parent > 0}
    indices, weights = [], []
    for vertex in points:
        point = Gf.Vec3d(vertex)
        scores = []
        for i, (name, _, _) in enumerate(JOINTS):
            if i == 0:
                d = distance(point, Gf.Vec3d(-0.42, -0.1, 0), Gf.Vec3d(0.24, -0.1, 0)) / 0.15
            else:
                end = positions[children[i]] if i in children else positions[i]
                radius = 0.047 if "Shoulder" in name else 0.075
                if name.endswith("elbow"): radius = 0.037
                if name.endswith("wrist"): radius = 0.07
                if name.endswith("knee"): radius = 0.05
                if name.endswith("ankle"): radius = 0.075
                d = distance(point, positions[i], end) / radius
            scores.append((1 / (0.01 + d ** 4), i))
        chosen = sorted(scores, reverse=True)[:4]
        total = sum(weight for weight, _ in chosen)
        indices.extend(index for _, index in chosen)
        weights.extend(weight / total for weight, _ in chosen)
    return indices, weights


def build(source_path, output_path):
    source = Usd.Stage.Open(str(source_path))
    assert source
    cache = UsdGeom.XformCache()
    body = UsdGeom.Mesh(source.GetPrimAtPath("/root/TrackedBody/TrackedBodyMesh"))
    matrix = cache.GetLocalToWorldTransform(body.GetPrim())
    points = [Gf.Vec3f(matrix.Transform(Gf.Vec3d(p))) for p in body.GetPointsAttr().Get()]
    indices, weights = skin_weights(points)
    with tempfile.TemporaryDirectory(prefix="healthai-rig-") as work:
        usd_path = Path(work) / "TrackedPatient.usdc"
        stage = Usd.Stage.CreateNew(str(usd_path))
        root = UsdSkel.Root.Define(stage, "/TrackedPatient")
        stage.SetDefaultPrim(root.GetPrim())
        UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
        UsdGeom.SetStageMetersPerUnit(stage, 1)
        skeleton = UsdSkel.Skeleton.Define(stage, "/TrackedPatient/Skeleton")
        names = [name for name, _, _ in JOINTS]
        bind, rest = [], []
        for _, position, parent in JOINTS:
            bind.append(Gf.Matrix4d().SetTranslate(Gf.Vec3d(*position)))
            relative = Gf.Vec3d(*position) - (Gf.Vec3d(*JOINTS[parent][1]) if parent >= 0 else Gf.Vec3d(0))
            rest.append(Gf.Matrix4d().SetTranslate(relative))
        skeleton.CreateJointsAttr(Vt.TokenArray(names))
        skeleton.CreateBindTransformsAttr(Vt.Matrix4dArray(bind))
        skeleton.CreateRestTransformsAttr(Vt.Matrix4dArray(rest))
        for name, source_mesh in (("Body", body), ("Shell", UsdGeom.Mesh(source.GetPrimAtPath("/root/TrackedBodyOutline/TrackedBodyOutlineMesh")))):
            path = Sdf.Path("/TrackedPatient/" + name)
            assert Sdf.CopySpec(source.GetRootLayer(), source_mesh.GetPath(), stage.GetRootLayer(), path)
            mesh = UsdGeom.Mesh(stage.GetPrimAtPath(path))
            matrix = cache.GetLocalToWorldTransform(source_mesh.GetPrim())
            baked = [Gf.Vec3f(matrix.Transform(Gf.Vec3d(p))) for p in source_mesh.GetPointsAttr().Get()]
            assert len(baked) == len(points)
            UsdGeom.Xformable(mesh).ClearXformOpOrder()
            mesh.GetPointsAttr().Set(Vt.Vec3fArray(baked))
            normals = source_mesh.GetNormalsAttr().Get()
            if normals:
                mesh.GetNormalsAttr().Set(Vt.Vec3fArray([Gf.Vec3f(matrix.TransformDir(Gf.Vec3d(n)).GetNormalized()) for n in normals]))
            mesh.GetExtentAttr().Set(UsdGeom.PointBased.ComputeExtent(Vt.Vec3fArray(baked)))
            for prop in list(mesh.GetPrim().GetProperties()):
                if prop.GetName().startswith("material:"): mesh.GetPrim().RemoveProperty(prop.GetName())
            binding = UsdSkel.BindingAPI.Apply(mesh.GetPrim())
            binding.CreateSkeletonRel().SetTargets([skeleton.GetPath()])
            binding.CreateGeomBindTransformAttr(Gf.Matrix4d(1))
            binding.CreateJointsAttr(Vt.TokenArray(names))
            binding.CreateJointIndicesPrimvar(False, 4).Set(Vt.IntArray(indices))
            binding.CreateJointWeightsPrimvar(False, 4).Set(Vt.FloatArray(weights))
        stage.GetRootLayer().Save()
        assert UsdUtils.CreateNewUsdzPackage(Sdf.AssetPath(str(usd_path)), str(output_path))
    print(f"Rigged {len(points)} original vertices with {len(JOINTS)} joints: {output_path}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=RESOURCES / "Ghost.usdz")
    parser.add_argument("--output", type=Path, default=RESOURCES / "TrackedPatient.usdz")
    args = parser.parse_args()
    build(args.source, args.output)
