import CoreVideo
import Foundation

/// Copies a camera image into a buffer of this package's own, so a slow reader such as a body
/// pose search never holds one of ARKit's buffers. ARKit stops delivering frames when too many
/// of its buffers are held.
///
/// Not thread-safe: use one copier from one queue.
final class ImageCopier {
    private var pool: CVPixelBufferPool?
    private var poolShape: Shape?

    private struct Shape: Equatable {
        var width: Int
        var height: Int
        var format: OSType
    }

    /// A copy of `source`, plane by plane, with its colour attachments. Nil when no buffer could
    /// be made or either buffer would not lock.
    func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let shape = Shape(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source),
                          format: CVPixelBufferGetPixelFormatType(source))
        guard let target = makeBuffer(shape) else { return nil }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(target, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(target, []) }

        let planes = CVPixelBufferGetPlaneCount(source)
        guard planes == CVPixelBufferGetPlaneCount(target) else { return nil }
        if planes == 0 {
            guard Self.copyRows(from: CVPixelBufferGetBaseAddress(source), CVPixelBufferGetBytesPerRow(source),
                                to: CVPixelBufferGetBaseAddress(target), CVPixelBufferGetBytesPerRow(target),
                                rows: shape.height) else { return nil }
        }
        for plane in 0..<planes {
            guard Self.copyRows(from: CVPixelBufferGetBaseAddressOfPlane(source, plane),
                                CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                                to: CVPixelBufferGetBaseAddressOfPlane(target, plane),
                                CVPixelBufferGetBytesPerRowOfPlane(target, plane),
                                rows: CVPixelBufferGetHeightOfPlane(source, plane)) else { return nil }
        }
        // Vision reads the colour matrix from these when it turns YCbCr into colour.
        CVBufferPropagateAttachments(source, target)
        return target
    }

    /// Copies `rows` rows, each source row's bytes up to the shorter of the two strides. Both
    /// strides hold a whole row of samples, so nothing that matters is cut.
    private static func copyRows(from source: UnsafeMutableRawPointer?, _ sourceStride: Int,
                                 to target: UnsafeMutableRawPointer?, _ targetStride: Int, rows: Int) -> Bool {
        guard let source, let target else { return false }
        let rowBytes = min(sourceStride, targetStride)
        for row in 0..<rows {
            (target + row * targetStride).copyMemory(from: source + row * sourceStride, byteCount: rowBytes)
        }
        return true
    }

    private func makeBuffer(_ shape: Shape) -> CVPixelBuffer? {
        if shape != poolShape {
            pool = nil
            poolShape = nil
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: shape.format,
                kCVPixelBufferWidthKey: shape.width,
                kCVPixelBufferHeightKey: shape.height,
                // IOSurface backing lets Vision hand the copy to the GPU or Neural Engine without another copy.
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            ]
            var created: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created) == kCVReturnSuccess else {
                return nil
            }
            pool = created
            poolShape = shape
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess else { return nil }
        return buffer
    }
}
