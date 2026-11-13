import CoreGraphics
@testable import PlumbUI

/// A rendered picture as plain sRGB bytes, so a test can ask what colour a point is.
struct Pixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    /// How far a channel may be from the palette's value and still count: rounding, nothing more.
    private static let tolerance = 3

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = buffer
    }

    var bounds: CGRect {
        CGRect(x: 0, y: 0, width: width, height: height)
    }

    /// True when the pixel at (x, y), counted from the top left, is `swatch`.
    func matches(_ swatch: Theme.Swatch, x: Int, y: Int) -> Bool {
        count(of: swatch, in: CGRect(x: x, y: y, width: 1, height: 1), step: 1) == 1
    }

    /// How many pixels of `swatch` there are inside `rect`, sampling every `step` pixels.
    func count(of swatch: Theme.Swatch, in rect: CGRect, step: Int = 2) -> Int {
        scan(rect, step: step, for: swatch).matching
    }

    /// True when every sampled pixel inside `rect` is `swatch`.
    func isFlat(_ swatch: Theme.Swatch, in rect: CGRect, step: Int = 2) -> Bool {
        let result = scan(rect, step: step, for: swatch)
        return result.sampled > 0 && result.matching == result.sampled
    }

    /// The smallest rectangle that holds every pixel of `swatch` inside `rect`, or nil when there is none.
    func bounds(of swatch: Theme.Swatch, in rect: CGRect) -> CGRect? {
        var found: CGRect?
        for y in max(0, Int(rect.minY))..<min(height, Int(rect.maxY)) {
            for x in max(0, Int(rect.minX))..<min(width, Int(rect.maxX)) where matches(swatch, x: x, y: y) {
                let pixel = CGRect(x: x, y: y, width: 1, height: 1)
                found = found?.union(pixel) ?? pixel
            }
        }
        return found
    }

    private func scan(_ rect: CGRect, step: Int, for swatch: Theme.Swatch) -> (sampled: Int, matching: Int) {
        let red = Int((swatch.red * 255).rounded())
        let green = Int((swatch.green * 255).rounded())
        let blue = Int((swatch.blue * 255).rounded())
        var sampled = 0
        var matching = 0
        bytes.withUnsafeBufferPointer { pixels in
            for y in stride(from: max(0, Int(rect.minY)), to: min(height, Int(rect.maxY)), by: step) {
                for x in stride(from: max(0, Int(rect.minX)), to: min(width, Int(rect.maxX)), by: step) {
                    let offset = (y * width + x) * 4
                    sampled += 1
                    if abs(Int(pixels[offset]) - red) <= Self.tolerance,
                       abs(Int(pixels[offset + 1]) - green) <= Self.tolerance,
                       abs(Int(pixels[offset + 2]) - blue) <= Self.tolerance {
                        matching += 1
                    }
                }
            }
        }
        return (sampled, matching)
    }
}
