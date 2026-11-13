import Foundation

// Trace file format, version 1
// ----------------------------
// A trace is UTF-8 text with one JSON object per line ("JSON Lines"). Every line ends in "\n".
// Keys within an object are in alphabetical order.
//
//   line 1     the header
//                {"createdAt":"2026-11-11T02:49:00Z","device":"iPhone16,1","note":"...","version":1}
//   line 2...  one camera frame each, in the order they were captured
//                {"t": seconds since the session started,
//                 "intrinsics": {"fx":..,"fy":..,"cx":..,"cy":..,"width":..,"height":..},
//                 "pose": [16 numbers: the camera-to-world matrix, column after column],
//                 "trackingNormal": true or false,
//                 "handsU":.., "handsV":..,
//                 "hands":     {"width":..,"height":..,"depthsM":"<base64>","confidence":"<base64>"},
//                 "handsLuma": {"width":..,"height":..,"pitchPx":..,"pixels":"<base64>"},
//                 "handsLumaU":.., "handsLumaV":..,
//                 "referenceU":.., "referenceV":..,
//                 "reference": {the same shape as "hands"}}
//
// A key whose value is missing for a frame (no patch, no reference) is left out of that line.
//
// The big arrays are base64 of their raw bytes, row by row from the top-left of the patch:
//   "depthsM"     32-bit IEEE floats, little-endian, metres
//   "confidence"  one byte per sample: 0 low, 1 medium, 2 high
//   "pixels"      one byte per sample: brightness 0...255
// Stored this way a frame with a 24x24 depth patch, a 16x16 reference and a 32x96 luma patch is
// about 10 kB, so twenty seconds at thirty frames a second is about 6 MB.
//
// A recording cut off part-way through its last line still opens: that line is dropped.

/// Reads and writes recorded traces. The format is described at the top of this file.
public enum TraceFile {
    /// The format version this code writes and the only one it reads.
    public static let currentVersion = 1

    /// Why a trace could not be read or written.
    public enum Failure: Error, Equatable {
        /// The data holds no lines at all.
        case empty
        /// The header names a format version this code does not read.
        case unsupportedVersion(Int)
        /// A line is not the JSON it should be. Line 1 is the header.
        case unreadableLine(Int)
        /// The file to record into could not be created.
        case cannotCreate(URL)
    }

    /// Turns a whole recording into the bytes of a trace file.
    public static func encode(header: TraceHeader, frames: [TraceFrame]) throws -> Data {
        let encoder = makeEncoder()
        var data = try line(header, using: encoder)
        for frame in frames {
            data.append(try line(frame, using: encoder))
        }
        return data
    }

    /// Reads a whole trace file back into its header and frames.
    public static func decode(_ data: Data) throws -> (TraceHeader, [TraceFrame]) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = data.split(separator: newline)
        guard let first = lines.first else { throw Failure.empty }
        guard let header = try? decoder.decode(TraceHeader.self, from: Data(first)) else {
            throw Failure.unreadableLine(1)
        }
        guard header.version == currentVersion else { throw Failure.unsupportedVersion(header.version) }

        var frames: [TraceFrame] = []
        frames.reserveCapacity(lines.count - 1)
        for (offset, text) in lines.dropFirst().enumerated() {
            if let frame = try? decoder.decode(TraceFrame.self, from: Data(text)) {
                frames.append(frame)
                continue
            }
            // A recorder that was killed mid-write leaves a last line with no newline after it.
            let cutOffMidWrite = offset == lines.count - 2 && data.last != newline
            guard cutOffMidWrite else { throw Failure.unreadableLine(offset + 2) }
        }
        return (header, frames)
    }

    /// The encoder both the one-shot and the streaming writer use, so their files are the same.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Unescaped slashes keep base64 at its natural size; sorted keys make files comparable.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// One value as one line of the file, newline included.
    static func line<Value: Encodable>(_ value: Value, using encoder: JSONEncoder) throws -> Data {
        var data = try encoder.encode(value)
        data.append(newline)
        return data
    }

    private static let newline = UInt8(ascii: "\n")
}
