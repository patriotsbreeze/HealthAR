import CryptoKit
import Foundation
import PlumbGeometry

/// A trace recorded on the phone, read back with what it is and which file it came from.
public struct RecordedTrace: Sendable {
    /// What the recording says about itself.
    public var header: TraceHeader
    /// The frames, in the order they were captured.
    public var frames: [TraceFrame]
    /// Names this recording by its bytes, so a gain fitted on it can refuse to score it.
    public var fingerprint: TraceFingerprint

    /// Reads a trace from the bytes of a trace file.
    public init(data: Data) throws {
        (header, frames) = try TraceFile.decode(data)
        fingerprint = TraceFingerprint(of: data)
    }

    /// Reads a trace file from disk.
    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    /// A trace built in memory. Its fingerprint is that of the file it would be written as, so it
    /// matches the same frames read back from disk.
    public init(header: TraceHeader, frames: [TraceFrame]) throws {
        self.header = header
        self.frames = frames
        fingerprint = TraceFingerprint(of: try TraceFile.encode(header: header, frames: frames))
    }
}

/// The first 16 hex digits of a trace file's SHA-256: enough to tell recordings apart, short enough to print.
public struct TraceFingerprint: Sendable, Hashable, CustomStringConvertible {
    /// The hex digits.
    public let value: String

    /// The fingerprint of a trace file's bytes.
    public init(of data: Data) {
        value = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The hex digits, as printed.
    public var description: String { value }
}
