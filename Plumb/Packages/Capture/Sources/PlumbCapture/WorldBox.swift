import CoreGraphics
import Foundation
import PlumbGeometry
import simd

/// An upright rectangle fixed in the world and turned square to the camera: the hands box, or the
/// square read at the reference.
struct WorldBox: Sendable, Equatable {
    /// Centre of the rectangle in world space, in metres.
    var centre: SIMD3<Double>
    /// Extent along the level direction square to the lens axis, in metres.
    var widthM: Double
    /// Extent along world-up, in metres.
    var heightM: Double

    /// The level world direction square to the lens axis, pointing to the camera's right. Nil when
    /// the camera looks straight up or down, where no such direction is defined.
    static func sideways(of pose: CameraPose) -> SIMD3<Double>? {
        // Column 2 of the pose is the camera's back axis; across it and world-up lies "sideways",
        // the same way the luma grid takes it.
        let back = SIMD3(Double(pose.columns[8]), Double(pose.columns[9]), Double(pose.columns[10]))
        let side = simd_cross(SIMD3(0, 1, 0), back)
        let length = simd_length(side)
        return length > 1e-6 ? side / length : nil
    }

    /// The image rectangle, in pixels, that holds the whole box as this camera sees it. Nil when a
    /// corner is behind the camera or the camera looks straight along the vertical.
    func imageBounds(intrinsics: Intrinsics, pose: CameraPose) -> CGRect? {
        guard let side = Self.sideways(of: pose) else { return nil }
        let up = SIMD3<Double>(0, 1, 0)
        var low = SIMD2(Double.infinity, Double.infinity)
        var high = -low
        for (across, along) in [(-1.0, -1.0), (-1, 1), (1, -1), (1, 1)] {
            let corner = centre + side * (across * widthM / 2) + up * (along * heightM / 2)
            guard let seen = Projection.project(corner, intrinsics: intrinsics, pose: pose) else { return nil }
            low = simd_min(low, SIMD2(seen.u, seen.v))
            high = simd_max(high, SIMD2(seen.u, seen.v))
        }
        return CGRect(x: low.x, y: low.y, width: high.x - low.x, height: high.y - low.y)
    }

    /// `imageBounds` as a share of the image, 0...1 from the top-left; not clipped to the image.
    func normalizedBounds(intrinsics: Intrinsics, pose: CameraPose) -> CGRect? {
        guard intrinsics.width > 0, intrinsics.height > 0,
              let pixels = imageBounds(intrinsics: intrinsics, pose: pose) else { return nil }
        let width = CGFloat(intrinsics.width), height = CGFloat(intrinsics.height)
        return CGRect(x: pixels.minX / width, y: pixels.minY / height,
                      width: pixels.width / width, height: pixels.height / height)
    }
}
