import CoreVideo
import Foundation
import PlumbGeometry

/// Reads brightness from the luma plane of the camera image, the Y of its YCbCr.
enum LumaSampler {
    /// Lays `grid` over the luma plane of `image` and reads a patch from it. Nil when the image is
    /// not the bi-planar YCbCr ARKit delivers, or will not lock.
    static func sample(_ grid: LumaGrid, from image: CVPixelBuffer) -> LumaPatch? {
        PlaneView.reading(image, plane: 0, formats: lumaFormats) { plane in
            grid.sample { u, v in brightness(of: plane, u: u, v: v) }
        }
    }

    /// Brightness at image position (u, v), blended from the four nearest pixels. Whole numbers
    /// are pixel centres. A position beyond the edge reads the nearest edge pixel, so the patch
    /// never picks up a false dark border.
    static func brightness(of plane: PlaneView, u: Double, v: Double) -> UInt8 {
        guard plane.width > 0, plane.height > 0, u.isFinite, v.isFinite else { return 0 }
        let x = min(max(u, 0), Double(plane.width - 1))
        let y = min(max(v, 0), Double(plane.height - 1))
        let left = Int(x), top = Int(y)
        let right = min(left + 1, plane.width - 1), bottom = min(top + 1, plane.height - 1)
        let across = x - Double(left), down = y - Double(top)
        func pixel(_ column: Int, _ row: Int) -> Double {
            Double(plane.base.load(fromByteOffset: row * plane.bytesPerRow + column, as: UInt8.self))
        }
        let upper = pixel(left, top) * (1 - across) + pixel(right, top) * across
        let lower = pixel(left, bottom) * (1 - across) + pixel(right, bottom) * across
        return UInt8(min(max((upper * (1 - down) + lower * down).rounded(), 0), 255))
    }

    /// Full-range is what ARKit gives; video-range has the same luma plane layout.
    private static let lumaFormats: Set<OSType> = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                                   kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
}
