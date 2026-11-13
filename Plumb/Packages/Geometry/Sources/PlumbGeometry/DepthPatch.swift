import Foundation

/// A small rectangle cut from the LiDAR depth map.
///
/// Samples run row by row from the top-left. `depthsM` and `confidence` each hold
/// `width * height` values. Two patches holding NaN never compare equal, as with any float.
public struct DepthPatch: Sendable, Equatable {
    /// Samples per row.
    public var width: Int
    /// Number of rows.
    public var height: Int
    /// Planar depth of each sample in metres. Not-a-number, infinite or zero mean "no reading".
    public var depthsM: [Float]
    /// How sure the sensor was of each sample: 0 low, 1 medium, 2 high.
    /// Left empty when the sensor gave none, and then every sample counts as high.
    public var confidence: [UInt8]

    /// Builds a patch from its samples, row by row from the top-left.
    public init(width: Int, height: Int, depthsM: [Float], confidence: [UInt8]) {
        self.width = width
        self.height = height
        self.depthsM = depthsM
        self.confidence = confidence
    }
}

// MARK: - Codable

extension DepthPatch: Codable {
    private enum CodingKeys: String, CodingKey {
        case width, height, depthsM, confidence
    }

    /// Reads a patch whose sample arrays are base64 of raw little-endian bytes.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        guard let depths = PackedBytes.unpackFloats(try container.decode(String.self, forKey: .depthsM)) else {
            throw DecodingError.dataCorruptedError(
                forKey: .depthsM, in: container, debugDescription: "Depths are not base64 of 32-bit floats")
        }
        guard let levels = PackedBytes.unpackBytes(try container.decode(String.self, forKey: .confidence)) else {
            throw DecodingError.dataCorruptedError(
                forKey: .confidence, in: container, debugDescription: "Confidence is not base64 bytes")
        }
        depthsM = depths
        confidence = levels
    }

    /// Writes the patch with its sample arrays as base64 of raw little-endian bytes.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(PackedBytes.pack(depthsM), forKey: .depthsM)
        try container.encode(PackedBytes.pack(confidence), forKey: .confidence)
    }
}
