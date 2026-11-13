import Foundation

/// Packs the big sample arrays as base64 of their raw little-endian bytes, the form they take in a
/// trace file. Written as JSON numbers the same arrays would be several times larger.
enum PackedBytes {
    static func pack(_ floats: [Float]) -> String {
        var data = Data(capacity: floats.count * floatSize)
        for value in floats {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data.base64EncodedString()
    }

    /// Nil when the text is not base64 or does not hold a whole number of floats.
    static func unpackFloats(_ text: String) -> [Float]? {
        guard let data = Data(base64Encoded: text), data.count % floatSize == 0 else { return nil }
        return data.withUnsafeBytes { raw in
            (0..<data.count / floatSize).map { index in
                let bits = raw.loadUnaligned(fromByteOffset: index * floatSize, as: UInt32.self)
                return Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
    }

    static func pack(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
    }

    /// Nil when the text is not base64.
    static func unpackBytes(_ text: String) -> [UInt8]? {
        Data(base64Encoded: text).map { [UInt8]($0) }
    }

    private static let floatSize = MemoryLayout<UInt32>.size
}
