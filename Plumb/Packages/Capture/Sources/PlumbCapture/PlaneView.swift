import CoreVideo
import Foundation

/// A read-only look at one plane of samples laid out row by row, where each row starts
/// `bytesPerRow` after the last. That stride is the buffer's own and is often more than
/// `width` samples, because rows are padded for alignment.
///
/// The memory belongs to someone else: a view is only good inside the closure that handed it out.
struct PlaneView {
    /// First byte of the first row.
    let base: UnsafeRawPointer
    /// Samples per row.
    let width: Int
    /// Number of rows.
    let height: Int
    /// Bytes from the start of one row to the start of the next.
    let bytesPerRow: Int

    /// Copies every sample out, row by row, leaving the padding behind. Empty when the plane is
    /// empty or its rows are too short to hold `width` samples of this type.
    func samples<Sample: BitwiseCopyable>(of type: Sample.Type) -> [Sample] {
        let rowBytes = width * MemoryLayout<Sample>.stride
        guard width > 0, height > 0, rowBytes <= bytesPerRow else { return [] }
        return [Sample](unsafeUninitializedCapacity: width * height) { buffer, initialized in
            let target = UnsafeMutableRawPointer(buffer.baseAddress!)
            for row in 0..<height {
                (target + row * rowBytes).copyMemory(from: base + row * bytesPerRow, byteCount: rowBytes)
            }
            initialized = width * height
        }
    }

    /// Locks `buffer` for reading, shows `body` the plane at `plane` (nil for a buffer without
    /// planes), then unlocks it. Nil, without calling `body`, when the buffer is not one of
    /// `formats`, will not lock, or has no memory behind it.
    static func reading<Result>(_ buffer: CVPixelBuffer, plane: Int?, formats: Set<OSType>,
                                _ body: (PlaneView) -> Result) -> Result? {
        guard formats.contains(CVPixelBufferGetPixelFormatType(buffer)) else { return nil }
        if let plane, plane >= CVPixelBufferGetPlaneCount(buffer) { return nil }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        // Unlock with the same flags it was locked with, whatever happens below.
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let view: PlaneView?
        if let plane {
            view = CVPixelBufferGetBaseAddressOfPlane(buffer, plane).map {
                PlaneView(base: UnsafeRawPointer($0), width: CVPixelBufferGetWidthOfPlane(buffer, plane),
                          height: CVPixelBufferGetHeightOfPlane(buffer, plane),
                          bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, plane))
            }
        } else {
            view = CVPixelBufferGetBaseAddress(buffer).map {
                PlaneView(base: UnsafeRawPointer($0), width: CVPixelBufferGetWidth(buffer),
                          height: CVPixelBufferGetHeight(buffer), bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
            }
        }
        return view.map(body)
    }
}
