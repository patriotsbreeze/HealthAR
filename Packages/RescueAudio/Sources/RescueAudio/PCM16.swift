import Foundation

/// 16-bit little-endian PCM, as the model sends and receives it.
enum PCM16 {
    static func data(from samples: [Int16]) -> Data {
        samples.map(\.littleEndian).withUnsafeBytes { Data($0) }
    }
}

/// Turns model audio into floats, holding a stray byte until the next chunk arrives.
struct PCM16Decoder: Sendable {
    private var carry: UInt8?

    mutating func decode(_ data: Data) -> [Float] {
        var output: [Float] = []
        output.reserveCapacity((data.count + 1) / 2)
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var index = 0
            if let low = carry, !bytes.isEmpty {
                output.append(Self.sample(low: low, high: bytes[0]))
                carry = nil
                index = 1
            }
            while index + 1 < bytes.count {
                output.append(Self.sample(low: bytes[index], high: bytes[index + 1]))
                index += 2
            }
            if index < bytes.count { carry = bytes[index] }
        }
        return output
    }

    mutating func reset() {
        carry = nil
    }

    private static func sample(low: UInt8, high: UInt8) -> Float {
        Float(Int16(bitPattern: UInt16(low) | UInt16(high) << 8)) / 32768
    }
}
