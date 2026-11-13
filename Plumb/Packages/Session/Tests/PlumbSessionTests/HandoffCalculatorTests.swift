import Foundation
import PlumbContracts
import Testing
@testable import PlumbSession

@Suite struct HandoffCalculatorTests {
    /// A 22 second session small enough to work out on paper.
    ///
    /// Ten compressions in three runs, with pauses of 8 s (4.25 to 12.25) and 3 s (13.5 to 16.5).
    /// Compressions 4 and 7 were measured while depth was not trusted.
    private func handBuiltLog() -> [LogEntry] {
        numbered([
            (0, .system, .sessionStarted(wallClock: fixtureStart)),
            (0.5, .measured, .lock(.locked)),
            (2.0, .measured, .compression(stroke(1, at: 2.0, depth: 40, interval: nil))),
            (2.5, .measured, .compression(stroke(2, at: 2.5, depth: 44, interval: 0.5))),
            (3.0, .measured, .compression(stroke(3, at: 3.0, depth: 50, interval: 0.5))),
            (3.75, .measured, .compression(stroke(4, at: 3.75, depth: 52, interval: 0.75, lock: .estimating))),
            (4.25, .measured, .compression(stroke(5, at: 4.25, depth: 56, interval: 0.5))),
            (5.0, .rule, .cue(.pushNow)),
            (12.25, .measured, .pause(start: 4.25, end: 12.25)),
            (12.25, .measured, .compression(stroke(6, at: 12.25, depth: 60, interval: nil))),
            (13.0, .measured, .compression(stroke(7, at: 13.0, depth: 58, interval: 0.75, lock: .rateOnly))),
            (13.5, .measured, .compression(stroke(8, at: 13.5, depth: 54, interval: 0.5))),
            (16.5, .measured, .pause(start: 13.5, end: 16.5)),
            (16.5, .measured, .compression(stroke(9, at: 16.5, depth: 62, interval: nil))),
            (17.0, .measured, .compression(stroke(10, at: 17.0, depth: 48, interval: 0.5))),
            (22.0, .system, .sessionEnded),
        ])
    }

    @Test func everyFieldOfAHandBuiltLogMatchesTheSumsDoneByHand() {
        let stats = HandoffCalculator.stats(log: handBuiltLog(), endT: 22)

        #expect(stats.startedWallClock == fixtureStart)
        #expect(stats.durationS == 22)
        #expect(stats.timeToFirstCompressionS == 2.0)
        #expect(stats.compressions == 10)

        // Intervals: 0.5, 0.5, 0.75, 0.5, 0.75, 0.5, 0.5. The middle of seven is 0.5, so 120 a minute.
        #expect(stats.ratePerMin == 120)

        // Trusted depths in order: 40, 44, 48, 50, 54, 56, 60, 62.
        // Typical: (50 + 54) / 2. Low: 0.1 x 7 = 0.7 of the way from 40 to 44.
        // High: 0.9 x 7 = 6.3, so 0.3 of the way from 60 to 62.
        #expect(stats.depthMM == 52)
        #expect(isClose(stats.depthLowMM, 42.8))
        #expect(isClose(stats.depthHighMM, 60.6))

        // 50, 54, 56, 60 and 62 reach the 50 mm target: 5 of 8. Trusted: 8 of 10.
        #expect(stats.reachedTargetFraction == 0.625)
        #expect(stats.trustedFraction == 0.8)

        #expect(stats.pauses == [
            HandoffStats.Pause(start: 4.25, durationS: 8),
            HandoffStats.Pause(start: 13.5, durationS: 3),
        ])
        #expect(stats.longestPauseS == 8)

        // 11 s paused out of the 20 s since the first compression.
        #expect(isClose(stats.handsOnFraction, 0.45))

        #expect(stats.buckets == [
            // Compressions 1 to 5; trusted 40, 44, 50, 56; paused from 4.25 to 10.
            HandoffStats.Bucket(start: 0, lengthS: 10, compressions: 5, depthMM: 47, pausedS: 5.75),
            // Compressions 6 to 10; trusted 48, 54, 60, 62; paused 10 to 12.25 and 13.5 to 16.5.
            HandoffStats.Bucket(start: 10, lengthS: 10, compressions: 5, depthMM: 57, pausedS: 5.25),
            HandoffStats.Bucket(start: 20, lengthS: 2, compressions: 0, depthMM: nil, pausedS: 0),
        ])
        #expect(stats.notRecorded == ["collapse time", "breathing", "shocks", "medicines"])
    }

    @Test func targetsAndSliceWidthCanBeChosen() {
        let strict = Targets(depthMinMM: 56)
        let stats = HandoffCalculator.stats(log: handBuiltLog(), endT: 22, targets: strict, bucketS: 5.5)

        // 56, 60 and 62 reach 56 mm: 3 of 8.
        #expect(stats.reachedTargetFraction == 0.375)
        #expect(stats.buckets.map(\.start) == [0, 5.5, 11, 16.5])
        #expect(stats.buckets.map(\.lengthS) == [5.5, 5.5, 5.5, 5.5])
        #expect(stats.buckets.map(\.compressions) == [5, 0, 3, 2])
        #expect(stats.buckets.map(\.pausedS) == [1.25, 5.5, 4.25, 0])
        #expect(stats.buckets.map(\.depthMM) == [47, nil, 57, 55])
    }

    @Test func aSessionBuiltFromSyntheticTruthAddsUp() throws {
        let segments = SyntheticSession.demo
        let truth = SyntheticSession.truth(segments)
        let endT = segments.reduce(0) { $0 + $1.duration }

        // Hand-made compressions straight from the truth: no analyzer is involved.
        var recorder = SessionRecorder(startedWallClock: fixtureStart)
        var expectedPauses: [HandoffStats.Pause] = []
        var previous: SyntheticSession.Truth.Bottom?
        for (index, bottom) in truth.bottoms.enumerated() {
            var interval: Double?
            if let previous {
                let stoodStill = truth.stillSpans.contains { $0.lowerBound >= previous.t && $0.upperBound <= bottom.t }
                if stoodStill {
                    recorder.record([.pauseStarted(at: previous.t),
                                     .pauseEnded(at: bottom.t, duration: bottom.t - previous.t)])
                    expectedPauses.append(HandoffStats.Pause(start: previous.t, durationS: bottom.t - previous.t))
                } else {
                    interval = bottom.t - previous.t
                }
            }
            recorder.record([.compression(stroke(index + 1, at: bottom.t, depth: bottom.depthMM, interval: interval))])
            previous = bottom
        }
        recorder.end(at: endT, openPauseSince: nil)
        let stats = HandoffCalculator.stats(log: recorder.log.entries, endT: endT)

        // The demo holds still twice, but only the second time comes after a compression.
        let pause = try #require(expectedPauses.first)
        #expect(expectedPauses.count == 1)
        #expect(stats.pauses.count == 1)
        #expect(isClose(stats.pauses.first?.start, pause.start))
        #expect(isClose(stats.pauses.first?.durationS, pause.durationS))
        #expect(isClose(stats.longestPauseS, pause.durationS))
        #expect(pause.durationS > 5 && pause.durationS < 6.5)

        let firstT = try #require(truth.bottoms.first?.t)
        #expect(stats.timeToFirstCompressionS == firstT)
        #expect(isClose(stats.handsOnFraction, 1 - pause.durationS / (endT - firstT)))

        #expect(stats.compressions == truth.bottoms.count)
        #expect(stats.trustedFraction == 1)
        #expect(stats.depthMM == 54)
        let rate = try #require(stats.ratePerMin)
        #expect(rate > 104 && rate < 112)

        // The slices cover the session with nothing lost and nothing counted twice.
        #expect(stats.buckets.map(\.start) == [0, 10, 20, 30])
        #expect(isClose(stats.buckets.reduce(0) { $0 + $1.lengthS }, endT))
        #expect(stats.buckets.reduce(0) { $0 + $1.compressions } == stats.compressions)
        #expect(isClose(stats.buckets.reduce(0) { $0 + $1.pausedS }, pause.durationS))
        for bucket in stats.buckets {
            let inSlice = truth.bottoms.filter { $0.t >= bucket.start && $0.t < bucket.start + bucket.lengthS }
            #expect(bucket.compressions == inSlice.count)
            #expect(bucket.pausedS <= bucket.lengthS)
        }
        #expect(stats.notRecorded == ["collapse time", "breathing", "shocks", "medicines"])
    }

    @Test func withNoTrustedCompressionsDepthIsNotRecorded() {
        let log = numbered([
            (0, .system, .sessionStarted(wallClock: fixtureStart)),
            (1.0, .measured, .compression(stroke(1, at: 1.0, depth: 45, interval: nil, lock: .estimating))),
            (1.5, .measured, .compression(stroke(2, at: 1.5, depth: 47, interval: 0.5, lock: .rateOnly))),
            (2.0, .measured, .compression(stroke(3, at: 2.0, depth: 49, interval: 0.5, lock: .lost))),
        ])
        let stats = HandoffCalculator.stats(log: log, endT: 5)

        #expect(stats.compressions == 3)
        #expect(stats.depthMM == nil)
        #expect(stats.depthLowMM == nil)
        #expect(stats.depthHighMM == nil)
        #expect(stats.reachedTargetFraction == nil)
        #expect(stats.trustedFraction == 0)
        #expect(stats.ratePerMin == 120)
        #expect(stats.buckets.map(\.depthMM) == [nil])
        #expect(stats.notRecorded == ["collapse time", "breathing", "shocks", "medicines", "depth"])
        #expect(HandoffText.depthRange(stats) == nil)
    }

    @Test func aSingleCompressionHasNoRate() {
        let log = numbered([
            (0, .system, .sessionStarted(wallClock: fixtureStart)),
            (1.0, .measured, .compression(stroke(1, at: 1.0, depth: 51, interval: nil))),
        ])
        let stats = HandoffCalculator.stats(log: log, endT: 5)

        #expect(stats.ratePerMin == nil)
        #expect(stats.depthMM == 51)
        #expect(stats.handsOnFraction == 1)
        #expect(stats.notRecorded == ["collapse time", "breathing", "shocks", "medicines", "rate"])
    }

    @Test func anEmptySessionRecordsNothingAndInventsNothing() {
        let log = numbered([(0, .system, .sessionStarted(wallClock: fixtureStart))])
        let stats = HandoffCalculator.stats(log: log, endT: 12)

        #expect(stats.compressions == 0)
        #expect(stats.timeToFirstCompressionS == nil)
        #expect(stats.ratePerMin == nil)
        #expect(stats.depthMM == nil)
        #expect(stats.trustedFraction == nil)
        #expect(stats.handsOnFraction == nil)
        #expect(stats.pauses.isEmpty)
        #expect(stats.longestPauseS == nil)
        #expect(stats.buckets.map(\.lengthS) == [10, 2])
        #expect(stats.notRecorded == ["collapse time", "breathing", "shocks", "medicines", "depth", "rate"])

        let nothing = HandoffCalculator.stats(log: [], endT: 0)
        #expect(nothing.startedWallClock == nil)
        #expect(nothing.durationS == 0)
        #expect(nothing.buckets.isEmpty)
    }

    @Test func aPauseIsCountedOnlyForThePartInsideTheSession() {
        let log = numbered([
            (0, .system, .sessionStarted(wallClock: fixtureStart)),
            (1.0, .measured, .compression(stroke(1, at: 1.0, depth: 51, interval: nil))),
            (9.0, .measured, .pause(start: 1.0, end: 9.0)),
        ])
        let stats = HandoffCalculator.stats(log: log, endT: 5)

        #expect(stats.pauses == [HandoffStats.Pause(start: 1, durationS: 4)])
        #expect(stats.longestPauseS == 4)
        #expect(stats.handsOnFraction == 0)
        #expect(stats.buckets.map(\.pausedS) == [4])
    }

    @Test func aVeryLongSessionGetsWiderSlicesNotMoreOfThem() {
        let config = SessionConfig(bucketS: 10, maxBuckets: 6)
        let stats = HandoffCalculator.stats(log: [], endT: 120, targets: .adult, config: config)
        #expect(stats.buckets.map(\.start) == [0, 20, 40, 60, 80, 100])
        #expect(stats.buckets.map(\.lengthS) == [20, 20, 20, 20, 20, 20])

        // A slice width that makes no sense falls back to the shipped one.
        let fallback = HandoffCalculator.stats(log: [], endT: 30, bucketS: 0)
        #expect(fallback.buckets.map(\.lengthS) == [10, 10, 10])
    }

    @Test func sessionLengthThatIsAHairOverAWholeSliceMakesNoSliverSlice() {
        let stats = HandoffCalculator.stats(log: [], endT: 30.000000000000004)
        #expect(stats.buckets.count == 3)
        #expect(isClose(stats.buckets.reduce(0) { $0 + $1.lengthS }, 30))
    }
}
