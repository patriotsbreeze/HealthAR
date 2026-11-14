"""Validate the smooth USD skin and Blender coordinate conversion. Requires usd-core."""
import unittest
from pathlib import Path
from pxr import Gf, Usd, UsdGeom, UsdSkel, Vt

RESOURCES = Path(__file__).resolve().parents[1] / "Packages/RescueVision/Sources/RescueVision/Resources"

class TrackedSkinTests(unittest.TestCase):
    def setUp(self):
        self.source = Usd.Stage.Open(str(RESOURCES / "Ghost.usdz"))
        self.stage = Usd.Stage.Open(str(RESOURCES / "TrackedPatient.usdz"))
        self.cache = UsdSkel.Cache()
        self.cache.Populate(UsdSkel.Root(self.stage.GetDefaultPrim()), Usd.PrimDefaultPredicate)
        self.skeleton = self.cache.GetSkelQuery(UsdSkel.Skeleton(self.stage.GetPrimAtPath("/TrackedPatient/Skeleton")))
        self.mesh = UsdGeom.Mesh(self.stage.GetPrimAtPath("/TrackedPatient/Body"))
        self.skin = self.cache.GetSkinningQuery(self.mesh.GetPrim())

    def test_baked_vertices_preserve_blender_world_coordinates_and_topology(self):
        source = UsdGeom.Mesh(self.source.GetPrimAtPath("/root/TrackedBody/TrackedBodyMesh"))
        transform = UsdGeom.XformCache().GetLocalToWorldTransform(source.GetPrim())
        points = self.mesh.GetPointsAttr().Get()
        self.assertEqual(len(points), len(source.GetPointsAttr().Get()))
        self.assertEqual(self.mesh.GetFaceVertexIndicesAttr().Get(), source.GetFaceVertexIndicesAttr().Get())
        error = max((Gf.Vec3d(a) - transform.Transform(Gf.Vec3d(b))).GetLength() for a,b in zip(points,source.GetPointsAttr().Get()))
        self.assertLess(error, 1e-6)
        # The old renderer dropped this nonidentity root conversion when cloning the child.
        self.assertNotEqual(transform, Gf.Matrix4d(1))

    def test_rest_skinning_keeps_the_original_smooth_surface(self):
        self.assertEqual(len(self.skeleton.GetJointOrder()), 13)
        original = self.mesh.GetPointsAttr().Get()
        skinned = Vt.Vec3fArray(original)
        self.assertTrue(self.skin.ComputeSkinnedPoints(self.skeleton.ComputeSkinningTransforms(Usd.TimeCode.Default()), skinned, Usd.TimeCode.Default()))
        self.assertLess(max((Gf.Vec3d(a)-Gf.Vec3d(b)).GetLength() for a,b in zip(skinned,original)), 1e-6)

    def test_body_and_outline_share_normalized_skin_weights(self):
        body = UsdSkel.BindingAPI(self.mesh.GetPrim())
        shell = UsdSkel.BindingAPI(self.stage.GetPrimAtPath("/TrackedPatient/Shell"))
        self.assertEqual(body.GetJointIndicesPrimvar().Get(),shell.GetJointIndicesPrimvar().Get())
        weights = body.GetJointWeightsPrimvar().Get()
        self.assertEqual(weights,shell.GetJointWeightsPrimvar().Get())
        for i in range(0,len(weights),4): self.assertAlmostEqual(sum(weights[i:i+4]),1,places=6)

    def test_raised_arm_deforms_the_smooth_mesh_without_dragging_the_torso(self):
        transforms = self.skeleton.ComputeSkinningTransforms(Usd.TimeCode.Default())
        shoulder = Gf.Vec3d(0.16,-0.1,0.2)
        deformation = Gf.Matrix4d().SetTranslate(-shoulder) * Gf.Matrix4d().SetRotate(Gf.Rotation(Gf.Vec3d(0,1,0),90)) * Gf.Matrix4d().SetTranslate(shoulder)
        for i in (1,2,3): transforms[i] = deformation
        original = self.mesh.GetPointsAttr().Get()
        skinned = Vt.Vec3fArray(original)
        self.assertTrue(self.skin.ComputeSkinnedPoints(transforms, skinned, Usd.TimeCode.Default()))
        arm = [(Gf.Vec3d(a)-Gf.Vec3d(b)).GetLength() for a,b in zip(skinned,original) if b[2]>0.22 and -0.4<b[0]<-0.05]
        torso = [(Gf.Vec3d(a)-Gf.Vec3d(b)).GetLength() for a,b in zip(skinned,original) if abs(b[2])<0.04 and -0.2<b[0]<0.05]
        self.assertTrue(arm and torso)
        self.assertGreater(sum(arm)/len(arm),0.1)
        self.assertLess(sum(torso)/len(torso),0.02)

if __name__ == "__main__": unittest.main()
