import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// What Vision found of the people in one picture, in the picture's own pixels.
struct PeopleSighting: Sendable, Equatable {
    /// Person coverage from 0 (no one) to 255 (a person), row by row from the top-left, spread over
    /// the whole picture at its own resolution.
    let coverage: [UInt8]
    /// Coverage values across.
    let coverageWidth: Int
    /// Coverage values down.
    let coverageHeight: Int
    /// Each face's box in picture pixels from the top-left, as tight as the detector gave it.
    let faces: [CGRect]
}

extension PeopleSighting {
    /// Runs person segmentation at its most careful quality and face detection on `picture`. Nil
    /// when either request fails or the mask cannot be read: the caller must then hide everything,
    /// which in practice means sending nothing.
    static func look(at picture: CGImage) async -> PeopleSighting? {
        let segmentation = GeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .accurate
        segmentation.outputPixelFormatType = kCVPixelFormatType_OneComponent8
        // Same assumption as `BodySearch`: the app runs in landscape with the phone's top to the
        // left, the sensor's native orientation, so people stand upright in the picture as it is.
        guard let mask = try? await segmentation.perform(on: picture, orientation: .up),
              let faces = try? await DetectFaceRectanglesRequest().perform(on: picture, orientation: .up),
              let maskPicture = try? mask.cgImage,
              let coverage = coverage(of: maskPicture) else { return nil }
        let size = CGSize(width: picture.width, height: picture.height)
        return PeopleSighting(coverage: coverage, coverageWidth: maskPicture.width, coverageHeight: maskPicture.height,
                              faces: faces.map { $0.boundingBox.toImageCoordinates(size, origin: .upperLeft) })
    }

    /// The mask's values, one byte a pixel, row by row from the top-left. Nil when the mask cannot be
    /// read without risk of reading too low, which would hide too little: a stencil, which has no
    /// colour of its own and would draw as all zeros, a picture with transparency or a decode array,
    /// or any colour space or layout other than the two below.
    ///
    /// A grey mask is drawn into a bitmap of its own grey colour space, so no value is changed on the
    /// way. Vision hands its one-byte mask over as a red, green and blue picture instead, because its
    /// `cgImage` goes through Core Image with no colour space named. That one is read straight from its
    /// bytes, each pixel as the largest of its red, green and blue, which for Vision's grey mask are all
    /// equal, so every value comes back as it was; were they ever not, the largest hides the most. It is
    /// not drawn, because drawing can take the unused fourth byte for transparency and blank the mask.
    static func coverage(of mask: CGImage) -> [UInt8]? {
        guard !mask.isMask, mask.decode == nil, let space = mask.colorSpace else { return nil }
        switch space.model {
        case .monochrome: return grey(mask, space: space)
        case .rgb: return largestOfRedGreenBlue(mask)
        default: return nil
        }
    }

    private static func grey(_ mask: CGImage, space: CGColorSpace) -> [UInt8]? {
        guard mask.alphaInfo == .none,
              let context = CGContext(data: nil, width: mask.width, height: mask.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.draw(mask, in: CGRect(x: 0, y: 0, width: mask.width, height: mask.height))
        guard let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var values: [UInt8] = []
        values.reserveCapacity(mask.width * mask.height)
        for row in 0..<mask.height {
            values.append(contentsOf: UnsafeBufferPointer(start: bytes + row * context.bytesPerRow, count: mask.width))
        }
        return values
    }

    /// The largest of each pixel's red, green and blue bytes, read in place. Which byte is which does not
    /// matter for the largest; only where the unused byte sits does, and that follows from the layout.
    private static func largestOfRedGreenBlue(_ mask: CGImage) -> [UInt8]? {
        guard mask.bitsPerComponent == 8, !mask.bitmapInfo.contains(.floatComponents),
              let colours = colourBytes(bitsPerPixel: mask.bitsPerPixel, alpha: mask.alphaInfo,
                                        order: mask.byteOrderInfo),
              let data = mask.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let pixelBytes = mask.bitsPerPixel / 8
        guard mask.width > 0, mask.height > 0, mask.bytesPerRow >= mask.width * pixelBytes,
              CFDataGetLength(data) >= (mask.height - 1) * mask.bytesPerRow + mask.width * pixelBytes else { return nil }
        var values: [UInt8] = []
        values.reserveCapacity(mask.width * mask.height)
        for row in 0..<mask.height {
            let rowStart = bytes + row * mask.bytesPerRow
            for column in 0..<mask.width {
                let pixel = rowStart + column * pixelBytes
                values.append(colours.reduce(0) { max($0, pixel[$1]) })
            }
        }
        return values
    }

    /// Where a pixel's red, green and blue bytes sit, in memory order, for the layouts with no
    /// transparency: three bytes a pixel, or four with the unused one first or last. Nil for any other,
    /// including every layout with transparency, which may have scaled the colours down.
    static func colourBytes(bitsPerPixel: Int, alpha: CGImageAlphaInfo, order: CGImageByteOrderInfo) -> [Int]? {
        let bigEndian = order == .orderDefault || order == .order32Big
        switch (bitsPerPixel, alpha) {
        case (24, .none) where bigEndian: return [0, 1, 2]
        case (32, .noneSkipFirst) where bigEndian, (32, .noneSkipLast) where order == .order32Little: return [1, 2, 3]
        case (32, .noneSkipLast) where bigEndian, (32, .noneSkipFirst) where order == .order32Little: return [0, 1, 2]
        default: return nil
        }
    }
}
