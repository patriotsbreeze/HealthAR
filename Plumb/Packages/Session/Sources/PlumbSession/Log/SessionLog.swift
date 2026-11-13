import Foundation
import PlumbContracts

/// The append-only record of one session. Ids count 1, 2, 3 and times never go backwards.
public struct SessionLog: Sendable, Equatable {
    /// Every entry so far, oldest first.
    public private(set) var entries: [LogEntry]

    /// An empty log.
    public init() {
        entries = []
    }

    /// Adds one entry and returns it as stored, with the next id.
    /// A time earlier than the last entry's (or before 0) is pulled up to it.
    @discardableResult
    public mutating func append(t: TimeInterval, source: LogEntry.Source, body: LogEntry.Body) -> LogEntry {
        let earliest = entries.last?.t ?? 0
        // Readers rely on the order of the log, so a time that would break it (earlier than the
        // last one, or not a number at all) is replaced rather than stored.
        let time = t.isFinite ? max(t, earliest) : earliest
        let entry = LogEntry(id: entries.count + 1, t: time, source: source, body: body)
        entries.append(entry)
        return entry
    }

    /// The whole log as text: one JSON object per line, UTF-8, keys always in the same order.
    public func ndjson() -> Data {
        LogLineCodec.data(for: entries)
    }

    /// Reads a log written by `ndjson()`. Throws `SessionLogError` when a line is not an entry
    /// or the entries are out of order.
    public init(ndjson: Data) throws {
        entries = try LogLineCodec.entries(from: ndjson)
    }
}

/// Why a saved log could not be read.
public enum SessionLogError: Error, Equatable, Sendable {
    /// The line with this number (1 for the first) is not a log entry.
    case unreadableLine(Int)
    /// The entry on this line breaks the 1, 2, 3 id order or goes back in time.
    case outOfOrder(line: Int)
}
