import CoreVideo
import Foundation
import PlumbGeometry
import simd
@testable import PlumbCapture

/// A camera like the iPhone's: 1920 x 1440 pixels with a 256 x 192 depth map.
enum TestScene {
    static let intrinsics = Intrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440)

    /// A level, upright camera at the origin looking along world -z: image up is world up.
    static let level = FrameCamera(intrinsics: intrinsics,
                                   pose: .looking(from: .zero, along: SIMD3(0, 0, -1)))

    /// A depth map of the iPhone's size whose every cell is `depth(column, row)`.
    static func depthMap(width: Int = 256, height: Int = 192, confidence: UInt8? = 2,
                         _ depth: (Int, Int) -> Float) -> DepthMap {
        var values: [Float] = []
        for row in 0..<height {
            for column in 0..<width { values.append(depth(column, row)) }
        }
        let levels = confidence.map { [UInt8](repeating: $0, count: width * height) } ?? []
        return DepthMap(width: width, height: height, depthsM: values, confidence: levels)
    }

    /// A bi-planar full-range YCbCr image, the format ARKit delivers, with luma `luma(u, v)` and flat chroma.
    static func image(width: Int = 1920, height: Int = 1440, luma: (Int, Int) -> UInt8) -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes, &made)
        let buffer = made!
        CVPixelBufferLockBaseAddress(buffer, [])
        let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for v in 0..<height {
            for u in 0..<width { lumaBase[v * lumaStride + u] = luma(u, v) }
        }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// Textured luma: stripes that change every few pixels down the image, so pictures can be matched.
    static func stripes(_ u: Int, _ v: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: (v / 6) * 37 + (u / 9) * 11)
    }
}
