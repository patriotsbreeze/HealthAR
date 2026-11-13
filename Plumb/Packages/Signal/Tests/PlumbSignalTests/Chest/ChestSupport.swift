import Foundation
import PlumbContracts
import Testing
@testable import PlumbSignal

/// Every reading one run of the chest check produced, one per tick.
struct ChestWatch {
    var readings: [ChestReading]
    var analyzer: ChestMovementAnalyzer

    var last: ChestReading? { readings.last }

    /// Time of the first reading that matches.
    func firstTime(where match: (ChestReading) -> Bool) -> TimeInterval? {
        readings.first(where: match)?.t
    }

    /// The readings between two times, both included.
    func readings(from start: TimeInterval, to end: TimeInterval) -> [ChestReading] {
        readings.filter { $0.t >= start - 1e-9 && $0.t <= end + 1e-9 }
    }
}

extension ChestReading.State {
    var isMovementSeen: Bool { self == .movementSeen }

    var isNoMovementSeen: Bool {
        if case .noMovementSeen = self { true } else { false }
    }

    var quietSeconds: Double? {
        if case .noMovementSeen(let seconds) = self { seconds } else { nil }
    }
}

/// Feeds samples to a chest check the way the app does: every sample, plus a tick ten times a second.
func watch(_ samples: [HeightSample], into analyzer: ChestMovementAnalyzer = ChestMovementAnalyzer(),
           tickEvery: TimeInterval = 0.1, until end: TimeInterval? = nil) -> ChestWatch {
    var analyzer = analyzer
    var readings: [ChestReading] = []
    var nextTick = (samples.first?.t ?? 0) + tickEvery
    for sample in samples {
        while nextTick < sample.t {
            readings.append(analyzer.tick(now: nextTick))
            nextTick += tickEvery
        }
        analyzer.ingest(sample)
    }
    let stop = end ?? (samples.last?.t ?? 0)
    while nextTick <= stop + 1e-9 {
        readings.append(analyzer.tick(now: nextTick))
        nextTick += tickEvery
    }
    return ChestWatch(readings: readings, analyzer: analyzer)
}

/// Total length of some segments, in seconds.
func length(of segments: [SyntheticChest.Segment]) -> TimeInterval {
    segments.reduce(0) { $0 + $1.duration }
}
