import Foundation
import PlumbContracts
import Testing
@testable import PlumbSignal

@Suite struct LifecycleTests {
    @Test func aNewAnalyzerKnowsNothing() {
        let analyzer = CompressionAnalyzer()
        #expect(analyzer.metrics == .empty)
        #expect(analyzer.live == LiveStroke())
        #expect(analyzer.metrics.lock == .lost)
    }

    @Test func resetReturnsToTheInitialState() {
        let samples = SyntheticSession.samples(SyntheticSession.demo, noiseMM: 2, seed: 4)
        let fresh = play(samples)

        var analyzer = fresh.analyzer
        #expect(analyzer.metrics.count > 0)
        analyzer.reset()
        #expect(analyzer.metrics == .empty)
        #expect(analyzer.live == LiveStroke())

        // After a reset the analyzer behaves exactly like a new one, event for event.
        let again = play(samples, into: analyzer)
        #expect(again.events == fresh.events)
        #expect(again.analyzer.metrics == fresh.analyzer.metrics)
        #expect(again.analyzer.live == fresh.analyzer.live)
    }

    @Test func resetKeepsConfigurationAndTargets() {
        var config = CompressionAnalyzer.Config()
        config.pauseAfterS = 1
        var analyzer = CompressionAnalyzer(config: config, targets: Targets(depthMinMM: 40))
        analyzer.reset()
        #expect(analyzer.config.pauseAfterS == 1)
        #expect(analyzer.targets.depthMinMM == 40)
    }

    @Test func theFirstSampleBringsTheSignalBack() {
        var analyzer = CompressionAnalyzer()
        let events = analyzer.ingest(HeightSample(t: 0.5, heightMM: 12, quality: 1))
        #expect(events == [.lockChanged(.rateOnly, at: 0.5)])
        #expect(analyzer.metrics.lock == .rateOnly)
        #expect(analyzer.metrics.t == 0.5)
        #expect(analyzer.live == LiveStroke(t: 0.5, currentDepthMM: 0, lock: .rateOnly))
    }

    @Test func liveDepthFollowsTheHandsAndIsNeverNegative() {
        let pace = Pace(rate: 110, depth: 50)
        let period = 60 / pace.rate
        let samples = SyntheticSession.samples(steady(rate: pace.rate, depth: pace.depth), noiseMM: 1, seed: 2)
        var analyzer = CompressionAnalyzer()
        var deepestPerCycle: [Int: Double] = [:]
        var restingDepths: [Double] = []
        for sample in samples {
            _ = analyzer.ingest(sample)
            let live = analyzer.live
            #expect(live.currentDepthMM >= 0)
            #expect(live.t == sample.t)
            #expect(live.lock == analyzer.metrics.lock)
            let cycle = Int(sample.t / period)
            deepestPerCycle[cycle] = max(deepestPerCycle[cycle] ?? 0, live.currentDepthMM)
            let phase = sample.t / period - Double(cycle)
            if cycle >= 2, phase > 0.85 { restingDepths.append(live.currentDepthMM) }
        }
        // The bar uses the smoothed height, so it reads a touch shallower than the measured stroke.
        for (cycle, deepest) in deepestPerCycle where cycle >= 1 && cycle < 35 {
            #expect(abs(deepest - pace.depth) < 6, "cycle \(cycle) peaked at \(deepest)")
        }
        #expect(median(restingDepths) < 3)
        #expect((restingDepths.max() ?? 99) < 8)
    }

    @Test func liveDepthRecoversAfterTheHandsSettleLower() {
        // Hands rest, then settle 30 mm lower over half a second and stay there.
        var rng = SplitMix64(seed: 5)
        var analyzer = CompressionAnalyzer()
        for index in 0..<(8 * 60) {
            let t = Double(index) / 60
            let settled = -30 * min(1, max(0, (t - 3) / 0.5))
            _ = analyzer.ingest(HeightSample(t: t, heightMM: settled + rng.nextGaussian()))
        }
        #expect(analyzer.live.currentDepthMM < 5)
        #expect(analyzer.metrics.count == 0)
    }

    @Test func ticksAloneMoveTheClock() {
        var analyzer = CompressionAnalyzer()
        #expect(analyzer.tick(now: 2).isEmpty)
        #expect(analyzer.metrics.t == 2)
        #expect(analyzer.tick(now: 1).isEmpty)
        #expect(analyzer.metrics.t == 2, "time never runs backwards")
        #expect(analyzer.tick(now: .nan).isEmpty)
        #expect(analyzer.metrics.lock == .lost)
    }
}
