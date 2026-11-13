import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing
@testable import RescueVision

private func decode(_ jpeg: Data) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

/// Normalized centroid of the bright pixels, origin top-left.
private func brightCentroid(_ image: CGImage) throws -> SIMD2<Double> {
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height)
    let context = try #require(CGContext(
        data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var sum = SIMD2<Double>(0, 0)
    var count = 0.0
    for y in 0..<height {
        for x in 0..<width where bytes[y * width + x] > 128 {
            sum += [Double(x) + 0.5, Double(y) + 0.5]
            count += 1
        }
    }
    return [sum.x / count / Double(width), sum.y / count / Double(height)]
}

@Test func scalesTheLongSideTo768() async throws {
    let encoder = FrameEncoder()
    let frame = CapturedFrame(id: 1, pixels: makePixels(width: 1920, height: 1440))

    let landscape = try decode(try #require(await encoder.encode(frame, rotation: .up)))
    #expect(landscape.width == 768)
    #expect(landscape.height == 576)

    let portrait = try decode(try #require(await encoder.encode(frame, rotation: .right)))
    #expect(portrait.width == 576)
    #expect(portrait.height == 768)
}

@Test func neverScalesUp() async throws {
    let frame = CapturedFrame(id: 1, pixels: makePixels(width: 320, height: 240))
    let image = try decode(try #require(await FrameEncoder().encode(frame, rotation: .up)))
    #expect(image.width == 320)
    #expect(image.height == 240)
}

@Test func encodesARKitsPixelFormat() async throws {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    let status = CVPixelBufferCreate(nil, 1920, 1440, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes, &buffer)
    #expect(status == kCVReturnSuccess)
    let frame = CapturedFrame(id: 1, pixels: try #require(buffer))
    let image = try decode(try #require(await FrameEncoder().encode(frame, rotation: .right)))
    #expect(image.width == 576)
    #expect(image.height == 768)
}

// A wrong rotation here would send the AED arrow to the wrong place, so check real pixels.
@Test(arguments: CaptureRotation.allCases)
func rotationMapsJPEGPointsBackToTheCapturedPixels(rotation: CaptureRotation) async throws {
    let rect = CGRect(x: 0.1, y: 0.15, width: 0.2, height: 0.3)
    let frame = CapturedFrame(id: 1, pixels: makePixels(width: 400, height: 300, whiteRect: rect))
    let jpeg = try #require(await FrameEncoder().encode(frame, rotation: rotation))
    let display = try brightCentroid(try decode(jpeg))
    let capture = rotation.captureNormalized(fromDisplay: display)
    #expect(isClose(capture, [Double(rect.midX), Double(rect.midY)], 0.02), "got \(capture)")
}
