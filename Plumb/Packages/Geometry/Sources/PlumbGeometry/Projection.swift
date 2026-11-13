import Foundation
import simd

/// Moves points between image pixels and the gravity-aligned world.
///
/// Conventions, used everywhere in this package:
/// - Image: u to the right, v downward, origin at the top-left of the native landscape image.
/// - Camera: +x right, +y up, looking along -z, so pixel (u, v) at planar depth z metres is the
///   camera point ((u - cx) * z / fx, -(v - cy) * z / fy, -z).
/// - World: +y is up; the pose maps camera points to world points.
/// - Depth is planar: distance along the lens axis, as LiDAR depth maps store it, not along the ray.
public enum Projection {
    /// The world point seen at pixel (u, v) when the surface there is `depthM` metres along the lens axis.
    public static func unproject(u: Double, v: Double, depthM: Double,
                                 intrinsics: Intrinsics, pose: CameraPose) -> SIMD3<Double> {
        let camera = SIMD3((u - intrinsics.cx) * depthM / intrinsics.fx,
                           -(v - intrinsics.cy) * depthM / intrinsics.fy,
                           -depthM)
        return pose.rotation * camera + pose.position
    }

    /// The pixel and planar depth at which a world point appears, or nil when it is behind the camera.
    public static func project(_ world: SIMD3<Double>, intrinsics: Intrinsics,
                               pose: CameraPose) -> (u: Double, v: Double, depthM: Double)? {
        let camera = cameraPoint(of: world, pose: pose)
        let depthM = -camera.z
        guard depthM > 0 else { return nil }
        return (intrinsics.cx + intrinsics.fx * camera.x / depthM,
                intrinsics.cy - intrinsics.fy * camera.y / depthM,
                depthM)
    }

    /// How many image pixels a 1 m move straight up covers at a world point, and the unit image
    /// direction of that move. Nil behind the camera, or when up runs straight along the line of sight.
    public static func pixelsPerMetreAlongUp(at world: SIMD3<Double>, intrinsics: Intrinsics,
                                             pose: CameraPose) -> (pixels: Double, direction: SIMD2<Double>)? {
        guard let motion = imageMotion(at: world, along: SIMD3(0, 1, 0), intrinsics: intrinsics, pose: pose) else {
            return nil
        }
        let pixels = simd_length(motion)
        guard pixels > vanishingMotion else { return nil }
        return (pixels, motion / pixels)
    }

    /// Image pixels per metre, as a (du, dv) vector, for a world point starting to move along the
    /// unit vector `direction`. Nil behind the camera.
    static func imageMotion(at world: SIMD3<Double>, along direction: SIMD3<Double>,
                            intrinsics: Intrinsics, pose: CameraPose) -> SIMD2<Double>? {
        let point = cameraPoint(of: world, pose: pose)
        let step = pose.rotation.transpose * direction
        let depthM = -point.z
        guard depthM > 0 else { return nil }
        // Derivative of u = cx + fx * x / z and v = cy - fy * y / z, where z = -point.z shrinks by step.z.
        let du = intrinsics.fx * (step.x * depthM + point.x * step.z) / (depthM * depthM)
        let dv = -intrinsics.fy * (step.y * depthM + point.y * step.z) / (depthM * depthM)
        return SIMD2(du, dv)
    }

    /// How far straight up, in metres, a point now at `world` has risen if its picture slid `upPx`
    /// pixels along the up direction to get there. Negative when it sank. Nil behind the camera.
    static func riseM(endingAt world: SIMD3<Double>, upPx: Double,
                      intrinsics: Intrinsics, pose: CameraPose) -> Double? {
        guard let scale = pixelsPerMetreAlongUp(at: world, intrinsics: intrinsics, pose: pose) else { return nil }
        let depthM = -cameraPoint(of: world, pose: pose).z
        // A tilted camera sees a rising point come nearer or go farther, so the scale changes
        // along the path. A point `rise` lower sat at depth `depthM + rise * upInCamera.z`, and
        // perspective gives upPx = rise * scale * depthM / thatDepth exactly. Solved for rise:
        let upInCamera = pose.rotation.transpose * SIMD3(0, 1, 0)
        let divisor = scale.pixels * depthM - upPx * upInCamera.z
        // A slide too long for any point in front of the camera to have made.
        guard divisor > 0 else { return nil }
        return upPx * depthM / divisor
    }

    /// The point on the line of sight through pixel (u, v) that passes closest, seen from above, to
    /// a spot on the floor plan given as (world x, world z). Nil when the line of sight is
    /// vertical, which says nothing about where along it the spot is, or the spot is behind the camera.
    static func point(onSightThroughU u: Double, v: Double, above spot: SIMD2<Double>,
                      intrinsics: Intrinsics, pose: CameraPose) -> SIMD3<Double>? {
        let origin = pose.position
        // The line of sight per metre of planar depth, and its shadow on the floor plan.
        let sight = unproject(u: u, v: v, depthM: 1, intrinsics: intrinsics, pose: pose) - origin
        let shadow = SIMD2(sight.x, sight.z)
        let shadowSquared = simd_length_squared(shadow)
        guard shadowSquared > vanishingMotion else { return nil }
        let depthM = simd_dot(spot - SIMD2(origin.x, origin.z), shadow) / shadowSquared
        guard depthM > 0 else { return nil }
        return origin + sight * depthM
    }

    /// Below this many pixels per metre the up direction has no usable image direction; the same
    /// floor stops a vertical line of sight from being divided by its vanishing shadow.
    private static let vanishingMotion = 1e-9

    /// A pose is rigid, so its inverse rotation is the transpose.
    private static func cameraPoint(of world: SIMD3<Double>, pose: CameraPose) -> SIMD3<Double> {
        pose.rotation.transpose * (world - pose.position)
    }
}
