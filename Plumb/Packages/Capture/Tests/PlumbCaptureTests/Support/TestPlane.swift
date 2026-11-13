import Foundation
import PlumbGeometry
import simd
@testable import PlumbCapture

extension TestScene {
    /// A depth map of the iPhone's size showing nothing but the flat surface through `point` square
    /// to `normal`, as `camera` sees it. Each cell holds the planar depth at its centre pixel; cells
    /// whose line of sight never meets the surface in front of the camera have no reading.
    static func planeDepth(seenBy camera: FrameCamera, through point: SIMD3<Double>,
                           normal: SIMD3<Double>) -> DepthMap {
        let cells = DepthCells(intrinsics: camera.intrinsics, mapWidth: 256, mapHeight: 192)
        let origin = camera.pose.position
        return depthMap { column, row in
            let pixel = cells.pixelCentre(column: column, row: row)
            let sight = Projection.unproject(u: pixel.u, v: pixel.v, depthM: 1,
                                             intrinsics: camera.intrinsics, pose: camera.pose) - origin
            let depth = simd_dot(normal, point - origin) / simd_dot(normal, sight)
            return depth.isFinite && depth > 0 ? Float(depth) : .nan
        }
    }

    /// A camera 0.6 m up, looking 30 degrees down along world -z: a phone propped low beside a chest.
    static let propped = FrameCamera(intrinsics: intrinsics,
                                     pose: .aimed(from: SIMD3(0, 0.6, 0), tiltDownRadians: .pi / 6))

    /// Where the propped camera's middle pixel meets the floor, y = 0.
    static let floorAhead = SIMD3<Double>(0, 0, -0.6 / tan(Double.pi / 6))
}
