import Foundation
import PlumbContracts

/// The part of the session log the scribe is shown: one compact line per entry, each with its id.
///
/// Only measurements and fixed events are included. Free text (notes, tool summaries, refusals,
/// object findings) is left out, so nothing a person or a model wrote can steer the scribe and
/// nothing personal leaves the phone.
struct ScribeLogDigest: Sendable {
    /// One line per included entry, oldest first.
    var lines: [String]
    /// The ids of the included entries, oldest first. These are the only ids the scribe may cite.
    var ids: [Int]
    /// True when the log was too long to show whole and was cut down.
    var thinned: Bool
    /// How many usable entries the log held before any thinning.
    var usableCount: Int

    init(log: [LogEntry], config: AgentsConfig) {
        var seen = Set<Int>()
        let usable = log.filter { Self.line(for: $0) != nil && seen.insert($0.id).inserted }
        usableCount = usable.count
        thinned = usable.count > config.scribeFullLogLimit
        let shown = thinned ? Self.thin(usable, stride: max(1, config.scribeCompressionStride)) : usable
        lines = shown.compactMap(Self.line(for:))
        ids = shown.map(\.id)
    }

    /// Keeps every pause, every nth compression, the first and last compression, and the first and
    /// last entry of the log. Everything else is dropped.
    private static func thin(_ entries: [LogEntry], stride: Int) -> [LogEntry] {
        let compressionAt = entries.indices.filter {
            if case .compression = entries[$0].body { return true }
            return false
        }
        var keep = Set<Int>()
        for (position, index) in compressionAt.enumerated() where position % stride == 0 {
            keep.insert(index)
        }
        for index in [compressionAt.first, compressionAt.last, entries.indices.first, entries.indices.last] {
            if let index { keep.insert(index) }
        }
        for index in entries.indices {
            if case .pause = entries[index].body { keep.insert(index) }
        }
        return keep.sorted().map { entries[$0] }
    }

    /// The line for one entry, or nil when the entry is not something the scribe may see.
    private static func line(for entry: LogEntry) -> String? {
        let what: String
        switch entry.body {
        case .sessionStarted:
            what = "session started"
        case .sessionEnded:
            what = "session ended"
        case .compression(let compression):
            // Depth is only a measurement while the lock is full; otherwise it is drawn, never judged.
            let depth = compression.lock == .locked ? "depth \(compression.depthMM.oneDecimal) mm" : "depth not trusted"
            let gap = compression.intervalS.map { ", \($0.oneDecimal) s after the one before" } ?? ""
            what = "compression number \(compression.index), \(depth)\(gap)"
        case .pause(let start, let end):
            what = "pause from \(start.oneDecimal) s to \(end.oneDecimal) s, lasting \((end - start).oneDecimal) s"
        case .lock(let state):
            what = "measurement trust became \(state.rawValue)"
        case .cue(let cue):
            what = "fixed spoken prompt \(cue.rawValue)"
        case .toolCall, .blocked, .found, .note:
            return nil
        }
        return "#\(entry.id) at \(entry.t.oneDecimal) s, \(entry.source.rawValue): \(what)"
    }
}
