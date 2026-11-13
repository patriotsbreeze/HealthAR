import Foundation
import simd
@testable import PlumbGeometry

/// The test renderer's own pinhole camera, written straight from the stated conventions and not
/// by calling `Projection`, so the two can disagree if either is wrong.
struct SceneCamera {
    let intrinsics: Intrinsics
    let position: SIMD3<Double>
    /// The camera's right, top and viewing directions in world space.
    let right: SIMD3<Double>
    let top: SIMD3<Double>
    let forward: SIMD3<Double>

    init(intrinsics: Intrinsics, pose: CameraPose) {
        self.intrinsics = intrinsics
        let c = pose.columns.map(Double.init)
        right = SIMD3(c[0], c[1], c[2])
        top = SIMD3(c[4], c[5], c[6])
        forward = -SIMD3(c[8], c[9], c[10])
        position = SIMD3(c[12], c[13], c[14])
    }

    /// World direction through a pixel, scaled so one unit of it is one metre of planar depth.
    func ray(_ pixel: SIMD2<Double>) -> SIMD3<Double> {
        let x = (pixel.x - intrinsics.cx) / intrinsics.fx
        let y = -(pixel.y - intrinsics.cy) / intrinsics.fy
        return right * x + top * y + forward
    }

    func planarDepth(of world: SIMD3<Double>) -> Double {
        simd_dot(world - position, forward)
    }

    func pixel(of world: SIMD3<Double>) -> SIMD2<Double> {
        let offset = world - position
        let depth = simd_dot(offset, forward)
        return SIMD2(intrinsics.cx + intrinsics.fx * simd_dot(offset, right) / depth,
                     intrinsics.cy - intrinsics.fy * simd_dot(offset, top) / depth)
    }
}

/// An upright rectangle of the image sampled on an even grid, the way a depth patch is cut.
struct ImageWindow {
    var centre: SIMD2<Double>
    var halfSize: SIMD2<Double>
    var columns: Int
    var rows: Int

    func pixel(column: Int, row: Int) -> SIMD2<Double> {
        let across = (Double(column) + 0.5) / Double(columns) * 2 - 1
        let down = (Double(row) + 0.5) / Double(rows) * 2 - 1
        return centre + SIMD2(across, down) * halfSize
    }
}
