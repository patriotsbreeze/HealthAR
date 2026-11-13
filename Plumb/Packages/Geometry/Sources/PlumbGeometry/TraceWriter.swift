import Foundation

/// Records a trace to disk one frame at a time, so a long recording never sits in memory.
///
/// The header is written when the writer is made and each frame is on disk when `append`
/// returns. Use one writer from one queue or actor at a time.
public final class TraceWriter {
    /// The file being written.
    public let url: URL
    /// Frames written so far.
    public private(set) var frameCount = 0

    private let handle: FileHandle
    private let encoder = TraceFile.makeEncoder()

    /// Creates the file, replacing any file already there, and writes the header line.
    public init(url: URL, header: TraceHeader) throws {
        let headerLine = try TraceFile.line(header, using: encoder)
        guard FileManager.default.createFile(atPath: url.path, contents: headerLine) else {
            throw TraceFile.Failure.cannotCreate(url)
        }
        self.url = url
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    /// Adds one frame as the next line of the file.
    public func append(_ frame: TraceFrame) throws {
        try handle.write(contentsOf: TraceFile.line(frame, using: encoder))
        frameCount += 1
    }

    /// Finishes the file. Appending after this throws.
    public func close() throws {
        try handle.close()
    }

    deinit {
        // A writer dropped without `close` must still let go of the file.
        try? handle.close()
    }
}
