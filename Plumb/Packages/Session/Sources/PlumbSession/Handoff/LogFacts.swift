import Foundation
import PlumbContracts

/// The parts of a log the handoff is computed from, pulled out once.
struct LogFacts {
    var startedWallClock: Date?
    var compressions: [Compression] = []
    private var pauseSpans: [ClosedRange<TimeInterval>] = []

    init(_ log: [LogEntry]) {
        for entry in log {
            switch entry.body {
            case .sessionStarted(let wallClock):
                if startedWallClock == nil { startedWallClock = wallClock }
            case .compression(let stroke):
                compressions.append(stroke)
            case .pause(let start, let end):
                if start.isFinite, end.isFinite, end >= start { pauseSpans.append(start...end) }
            case .sessionEnded, .lock, .cue, .toolCall, .blocked, .found, .note:
                break
            }
        }
    }

    /// Pauses cut to the session, 0 to `endT`, so every total made from them agrees with the
    /// chart slices. A pause with nothing left inside the session is dropped.
    func pauses(within endT: TimeInterval) -> [HandoffStats.Pause] {
        pauseSpans.compactMap { span in
            let start = max(0, span.lowerBound)
            let end = min(endT, span.upperBound)
            return end > start ? HandoffStats.Pause(start: start, durationS: end - start) : nil
        }
    }
}

extension Compression {
    /// True when this compression's depth may be reported and judged.
    var hasTrustedDepth: Bool {
        lock == .locked && depthMM.isFinite
    }
}

extension Array where Element == Compression {
    /// Depths of the compressions measured while depth was trusted, in order.
    var trustedDepthsMM: [Double] {
        filter(\.hasTrustedDepth).map(\.depthMM)
    }

    /// Gaps between one compression and the next. The first after a pause has none.
    var intervalsS: [Double] {
        compactMap(\.intervalS).filter { $0.isFinite && $0 > 0 }
    }

    /// Compressions per minute from the typical gap, or nil with fewer than `minIntervals` gaps.
    func typicalRatePerMin(minIntervals: Int) -> Double? {
        let intervals = intervalsS
        guard intervals.count >= minIntervals else { return nil }
        return Quantiles.median(intervals).map { Units.secondsPerMinute / $0 }
    }
}
