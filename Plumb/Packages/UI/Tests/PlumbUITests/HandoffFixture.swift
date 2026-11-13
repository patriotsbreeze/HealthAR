import Foundation
import PlumbContracts
@testable import PlumbUI

/// A made-up six-minute-forty session and the summary a crew would be handed for it.
@MainActor
enum HandoffFixture {
    static let segments: [SyntheticSegment] = [
        .pause(6),
        SyntheticSegment(duration: 60, ratePerMin: 104, depthMM: 41),
        SyntheticSegment(duration: 70, ratePerMin: 110, depthMM: 53),
        .pause(9),
        SyntheticSegment(duration: 80, ratePerMin: 112, depthMM: 55),
        .pause(5),
        SyntheticSegment(duration: 60, ratePerMin: 108, depthMM: 49),
        SyntheticSegment(duration: 50, ratePerMin: 110, depthMM: 54),
        .pause(4),
        SyntheticSegment(duration: 56, ratePerMin: 114, depthMM: 52),
    ]

    static let headline = "CPR started 14:02. Ran 6 min 40 s. 3 pauses, longest 9 s."

    static let sentences = [
        "Depth fell short for the first minute and reached the line after the first correction.",
        "The longest pause, 9 s, came 2 min 16 s in.",
    ]

    /// The summary with every field measured.
    static var full: HandoffStats {
        let strokes = Fixture.strokes(segments, scatterMM: 2.2)
        let truth = SyntheticSession.truth(segments)
        let duration = segments.reduce(0) { $0 + $1.duration }
        let first = strokes.first?.t ?? 0
        // The wait before the first push is not a pause; a pause is a gap between pushes.
        let pauses = truth.stillSpans.dropFirst().map {
            HandoffStats.Pause(start: $0.lowerBound, durationS: $0.upperBound - $0.lowerBound)
        }
        let depths = strokes.map(\.bar.depthMM).sorted()
        let paused = pauses.reduce(0) { $0 + $1.durationS }
        let sliceLength = 10.0
        let buckets = stride(from: 0, to: duration, by: sliceLength).map { start -> HandoffStats.Bucket in
            let slice = start..<(start + sliceLength)
            let inSlice = strokes.filter { slice.contains($0.t) }.map(\.bar.depthMM).sorted()
            let pausedS = pauses.reduce(0.0) { total, pause in
                total + max(0, min(slice.upperBound, pause.start + pause.durationS) - max(slice.lowerBound, pause.start))
            }
            return HandoffStats.Bucket(start: start, lengthS: sliceLength, compressions: inSlice.count,
                                       depthMM: inSlice.isEmpty ? nil : inSlice[inSlice.count / 2], pausedS: pausedS)
        }
        return HandoffStats(startedWallClock: nil,
                            durationS: duration,
                            timeToFirstCompressionS: first,
                            compressions: strokes.count,
                            ratePerMin: Double(strokes.count) / (duration - first - paused) * 60,
                            depthMM: depths[depths.count / 2],
                            depthLowMM: depths[depths.count / 10],
                            depthHighMM: depths[depths.count * 9 / 10],
                            reachedTargetFraction: Double(strokes.filter(\.bar.reached).count) / Double(strokes.count),
                            trustedFraction: 1,
                            handsOnFraction: 1 - paused / (duration - first),
                            pauses: Array(pauses),
                            longestPauseS: pauses.map(\.durationS).max(),
                            buckets: buckets,
                            notRecorded: ["breaths", "AED shocks", "who was compressing"])
    }

    /// The depth of the full summary as the range string the app would pass in.
    static var depthRange: String {
        let stats = full
        return "\(Int((stats.depthLowMM ?? 0).rounded()))–\(Int((stats.depthHighMM ?? 0).rounded())) mm"
    }

    /// The same session when depth was never trusted: only the rhythm and the pauses are known.
    static var withoutDepth: HandoffStats {
        var stats = full
        stats.depthMM = nil
        stats.depthLowMM = nil
        stats.depthHighMM = nil
        stats.reachedTargetFraction = nil
        stats.trustedFraction = 0
        stats.buckets = stats.buckets.map { bucket in
            var bucket = bucket
            bucket.depthMM = nil
            return bucket
        }
        stats.notRecorded = ["depth"] + stats.notRecorded
        return stats
    }
}
