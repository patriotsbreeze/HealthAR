import Foundation
import PlumbContracts
import Testing
@testable import PlumbSignal

@Suite struct AccuracyTests {
    static let seeds: [UInt64] = [1, 2, 3]

    @Test(arguments: Sampling.required, Pace.grid)
    func rateDepthAndCountMatchTruth(sampling: Sampling, pace: Pace) throws {
        let truth = SyntheticSession.truth(steady(rate: pace.rate, depth: pace.depth))
        for seed in Self.seeds {
            let run = play(sampling.samples(pace, seed: seed))
            let metrics = run.analyzer.metrics

            let rate = try #require(metrics.ratePerMin)
            #expect(abs(rate - pace.rate) <= 2, "rate \(rate), seed \(seed)")

            let typical = median(run.compressions.map(\.depthMM))
            #expect(abs(typical - pace.depth) <= 3, "median depth \(typical), seed \(seed)")
            let rolling = try #require(metrics.depthMM)
            #expect(abs(rolling - pace.depth) <= 3, "rolling depth \(rolling), seed \(seed)")

            #expect(abs(run.compressions.count - truth.bottoms.count) <= 1,
                    "counted \(run.compressions.count) of \(truth.bottoms.count), seed \(seed)")
            #expect(metrics.count == run.compressions.count)
        }
    }

    @Test(arguments: Sampling.required)
    func nineInTenStrokesAreWithinFiveMillimetres(sampling: Sampling) {
        for pace in Pace.grid {
            var errors: [Double] = []
            for seed in Self.seeds {
                errors += play(sampling.samples(pace, seed: seed)).compressions.map { abs($0.depthMM - pace.depth) }
            }
            let close = Double(errors.filter { $0 < 5 }.count) / Double(errors.count)
            #expect(close >= 0.9, "\(pace.testDescription): only \(close) of strokes within 5 mm")
        }
    }

    /// Half the samples and dropped frames on top: harder than anything required, so the bounds are wider.
    @Test(arguments: Pace.grid)
    func thirtyHertzWithDroppedSamplesStillHoldsUp(pace: Pace) throws {
        let truth = SyntheticSession.truth(steady(rate: pace.rate, depth: pace.depth))
        for seed in Self.seeds {
            let run = play(Sampling.thirtyHzEverySeventhDropped.samples(pace, seed: seed))
            #expect(abs(try #require(run.analyzer.metrics.ratePerMin) - pace.rate) <= 4)
            #expect(abs(median(run.compressions.map(\.depthMM)) - pace.depth) <= 3)
            #expect(abs(run.compressions.count - truth.bottoms.count) <= 1)
        }
    }

    @Test(arguments: [30.0, -30.0])
    func driftOfTheTopDoesNotChangeDepth(driftMMPerMin: Double) {
        for pace in Pace.grid {
            let segments = steady(rate: pace.rate, depth: pace.depth, seconds: 30)
            let still = play(SyntheticSession.samples(segments, noiseMM: 2, seed: 4))
            let drifting = play(SyntheticSession.samples(segments, noiseMM: 2, driftMMPerMin: driftMMPerMin, seed: 4))

            let stillDepth = median(still.compressions.map(\.depthMM))
            let driftingDepth = median(drifting.compressions.map(\.depthMM))
            #expect(abs(driftingDepth - stillDepth) <= 3, "\(pace.testDescription): \(stillDepth) became \(driftingDepth)")
            #expect(abs(driftingDepth - pace.depth) <= 3)
            #expect(drifting.compressions.count == still.compressions.count)
        }
    }

    @Test func eachStrokeCarriesItsOwnTimes() throws {
        let pace = Pace(rate: 110, depth: 50)
        let truth = SyntheticSession.truth(steady(rate: pace.rate, depth: pace.depth))
        let run = play(Sampling.sixtyHz.samples(pace))
        for (offset, stroke) in run.compressions.enumerated() {
            let bottom = try #require(nearest(truth.bottoms, to: stroke.tBottom))
            #expect(stroke.index == offset + 1)
            #expect(abs(stroke.tBottom - bottom.t) < 0.03, "deepest point at \(stroke.tBottom), truly \(bottom.t)")
            #expect(stroke.tTop < stroke.tBottom)
            #expect(stroke.tBottom - stroke.tTop < 60 / pace.rate)
            #expect(stroke.depthMM > 0)
        }
    }

    @Test func intervalsFollowTheRhythm() throws {
        let pace = Pace(rate: 120, depth: 50)
        let strokes = play(Sampling.sixtyHz.samples(pace)).compressions
        #expect(strokes.first?.intervalS == nil)
        for stroke in strokes.dropFirst() {
            let interval = try #require(stroke.intervalS)
            #expect(abs(interval - 0.5) < 0.04)
        }
    }

    @Test func rateNeedsTwoIntervals() {
        let samples = Sampling.sixtyHz.samples(Pace(rate: 120, depth: 50), seconds: 5)
        let run = play(samples)
        #expect(run.metricsAfterStroke[0].ratePerMin == nil)
        #expect(run.metricsAfterStroke[1].ratePerMin == nil)
        #expect(run.metricsAfterStroke[2].ratePerMin != nil)
    }

    @Test func aChangeOfDepthShowsWithinFourStrokes() throws {
        let segments = [wholeStrokes(16, rate: 104, depth: 38), wholeStrokes(12, rate: 110, depth: 54)]
        for seed in Self.seeds {
            let run = play(SyntheticSession.samples(segments, noiseMM: 2, seed: seed))
            #expect(run.compressions.count == 28)
            let before = try #require(run.metricsAfterStroke[15].depthMM)
            #expect(abs(before - 38) <= 3)
            let after = try #require(run.metricsAfterStroke[19].depthMM)
            #expect(abs(after - 54) <= 3, "four strokes in, depth reads \(after)")
        }
    }

    @Test func spreadIsSmallForSteadyStrokesAndGrowsForUnevenOnes() throws {
        let steadyRun = play(Sampling.sixtyHz.samples(Pace(rate: 110, depth: 50)))
        let steadySpread = try #require(steadyRun.analyzer.metrics.depthSpreadMM)
        #expect(steadySpread < 4)

        let uneven = (0..<12).map { wholeStrokes(1, rate: 110, depth: $0 % 2 == 0 ? 35 : 60) }
        let unevenRun = play(SyntheticSession.samples(uneven, noiseMM: 1, seed: 2))
        let unevenSpread = try #require(unevenRun.analyzer.metrics.depthSpreadMM)
        #expect(unevenSpread > 8)
    }
}
