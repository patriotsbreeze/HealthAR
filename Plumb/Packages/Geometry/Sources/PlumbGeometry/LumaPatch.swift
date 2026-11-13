import Foundation

/// Brightness samples on a small grid laid over the hands, turned to line up with gravity.
///
/// Rows run across the direction world-up takes in the image, and the row index grows downward
/// in the world: row 0 is the highest. Samples run row by row, `width * height` of them.
/// The grid keeps its size and spacing from frame to frame. It may stay put in the image while
/// the hands slide through it, or be moved, as long as the frame says where its centre is.
public struct LumaPatch: Sendable, Equatable {
    /// Samples per row.
    public var width: Int
    /// Number of rows.
    public var height: Int
    /// Distance between neighbouring rows, in image pixels.
    public var pitchPx: Double
    /// Brightness of each sample, 0 black to 255 white.
    public var pixels: [UInt8]

    /// Builds a patch from its samples, row by row starting with the highest row in the world.
    public init(width: Int, height: Int, pitchPx: Double, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pitchPx = pitchPx
        self.pixels = pixels
    }

    /// The patch boiled down to row means, kept separately for each of `bands` side-by-side strips.
    /// Nil when the sample count does not match the stated size or there is too little to compare.
    func rowProfiles(bands: Int) -> RowProfiles? {
        guard width > 0, height > 1, pixels.count == width * height else { return nil }
        let bandCount = min(max(bands, 1), width)
        var means = [Double](repeating: 0, count: bandCount * height)
        // Raw buffers: this runs on every camera frame, and unoptimised builds pay dearly for
        // checked array access in a loop this tight.
        means.withUnsafeMutableBufferPointer { target in
            pixels.withUnsafeBufferPointer { source in
                for band in 0..<bandCount {
                    let firstColumn = band * width / bandCount
                    let endColumn = (band + 1) * width / bandCount
                    for row in 0..<height {
                        var total = 0
                        var sample = row * width + firstColumn
                        let rowEnd = row * width + endColumn
                        while sample < rowEnd {
                            total += Int(source[sample])
                            sample += 1
                        }
                        target[band * height + row] = Double(total) / Double(endColumn - firstColumn)
                    }
                }
            }
        }
        return RowProfiles(bands: bandCount, rows: height, means: means)
    }
}

/// A luma patch reduced to the mean brightness of each row, strip by strip.
struct RowProfiles: Sendable {
    /// Vertical strips the patch was cut into.
    let bands: Int
    /// Rows in the patch.
    let rows: Int
    /// `bands * rows` means: every row of the first strip, then of the next.
    let means: [Double]
}

// MARK: - Codable

extension LumaPatch: Codable {
    private enum CodingKeys: String, CodingKey {
        case width, height, pitchPx, pixels
    }

    /// Reads a patch whose samples are base64 of one byte each.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        pitchPx = try container.decode(Double.self, forKey: .pitchPx)
        guard let samples = PackedBytes.unpackBytes(try container.decode(String.self, forKey: .pixels)) else {
            throw DecodingError.dataCorruptedError(
                forKey: .pixels, in: container, debugDescription: "Brightness samples are not base64 bytes")
        }
        pixels = samples
    }

    /// Writes the patch with its samples as base64 of one byte each.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(pitchPx, forKey: .pitchPx)
        try container.encode(PackedBytes.pack(pixels), forKey: .pixels)
    }
}
