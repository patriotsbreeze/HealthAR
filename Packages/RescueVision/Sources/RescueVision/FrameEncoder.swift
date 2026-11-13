import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// `CVPixelBuffer` isn't annotated as Sendable. These are only read after ARKit delivers them.
struct CapturedFrame: @unchecked Sendable {
    var id: UInt64
    var pixels: CVPixelBuffer
}

/// Scales to 768 px on the long side and encodes JPEG. An actor, so it runs off the main thread
/// and one at a time, which also bounds memory.
actor FrameEncoder {
    static let longSide: CGFloat = 768

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// The JPEG's pixels are physically rotated, so its normalized coordinates are the rotated
    /// image's. Map them back with `CaptureRotation.captureNormalized(fromDisplay:)`.
    func encode(_ frame: CapturedFrame, rotation: CaptureRotation, quality: Double = 0.7) -> Data? {
        var image = CIImage(cvPixelBuffer: frame.pixels).oriented(rotation.cgOrientation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))

        let longest = max(image.extent.width, image.extent.height)
        guard longest > 0 else { return nil }
        let scale = min(1, Self.longSide / longest)
        let width = (image.extent.width * scale).rounded()
        let height = (image.extent.height * scale).rounded()
        image = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))

        let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        return context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
    }
}
