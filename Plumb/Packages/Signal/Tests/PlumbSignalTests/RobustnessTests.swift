import Foundation
import PlumbContracts
import Testing
@testable import PlumbSignal

@Suite struct RobustnessTests {
    // MARK: Things that are not compressions

    @Test(arguments: [60.0, 30.0])
    func noiseAloneIsNeverACompression(sampleHz: Double) {
        for seed in UInt64(1)...12 {
            let run = play(idleSamples(seconds: 30, sampleHz: sampleHz, noiseMM: 3, seed: seed))
            #expect(run.compressions.isEmpty, "seed \(seed)")
            #expect(run.analyzer.metrics.count == 0)
            #expect(run.pauseStarts.isEmpty)
            #expect(run.analyzer.metrics.handsOnFraction == nil)
        }
    }

    @Test(arguments: [60.0, 30.0])
    func slowSwayIsNeverACompression(sampleHz: Double) {
        for seed in UInt64(1)...12 {
            let samples = idleSamples(seconds: 30, sampleHz: sampleHz, noiseMM: 2, swayMM: 15, swayHz: 0.3, seed: seed)
            #expect(play(samples).compressions.isEmpty, "seed \(seed)")
        }
    }

    @Test func liveDepthStaysNearZeroWhileTheHandsOnlySway() {
        let samples = idleSamples(seconds: 20, noiseMM: 1, swayMM: 15, swayHz: 0.3)
        var analyzer = CompressionAnalyzer()
        var deepest = 0.0
        for sample in samples {
            _ = analyzer.ingest(sample)
            deepest = max(deepest, analyzer.live.currentDepthMM)
        }
        #expect(deepest < 15)
    }

    // MARK: Spikes

    /// Adds a 60 mm spike, alternately up and down, to one sample in every `every`.
    private func withSpikes(_ samples: [HeightSample], every: Int) -> [HeightSample] {
        var spiked = samples
        var up = true
        for index in stride(from: every, to: samples.count, by: every) {
            spiked[index].heightMM += up ? 60 : -60
            up.toggle()
        }
        return spiked
    }

    @Test(arguments: [Sampling.sixtyHz, .thirtyHz], [19, 23, 31])
    func spikesNeitherAddNorRemoveCompressions(sampling: Sampling, every: Int) throws {
        let pace = Pace(rate: 110, depth: 50)
        let clean = sampling.samples(pace)
        let cleanRun = play(clean)
        let spikedRun = play(withSpikes(clean, every: every))

        #expect(spikedRun.compressions.count == cleanRun.compressions.count)
        for (spiked, original) in zip(spikedRun.compressions, cleanRun.compressions) {
            #expect(abs(spiked.tBottom - original.tBottom) < 0.05)
        }
        let typical = median(spikedRun.compressions.map(\.depthMM))
        #expect(abs(typical - pace.depth) <= 3)
        let rate = try #require(spikedRun.analyzer.metrics.ratePerMin)
        #expect(abs(rate - pace.rate) <= 2)
    }

    @Test(arguments: [60.0, 30.0])
    func spikesOnStillHandsAreNotCompressions(sampleHz: Double) {
        let idle = idleSamples(seconds: 30, sampleHz: sampleHz, noiseMM: 2)
        #expect(play(withSpikes(idle, every: 17)).compressions.isEmpty)
    }

    // MARK: The top moving

    /// A steady session whose height reference moves by `stepMM`, starting at `at` and taking `over` seconds.
    private func withStep(_ samples: [HeightSample], of stepMM: Double, at start: TimeInterval,
                          over ramp: TimeInterval) -> [HeightSample] {
        samples.map { sample in
            var moved = sample
            let progress = ramp > 0 ? min(1, max(0, (sample.t - start) / ramp)) : (sample.t >= start ? 1 : 0)
            moved.heightMM += stepMM * progress
            return moved
        }
    }

    struct Reseat: Sendable, CustomTestStringConvertible {
        var stepMM: Double
        /// Where in a stroke cycle the step lands: 0.2 is mid-descent, 0.85 is the rest at the top.
        var phase: Double
        var rampS: Double

        var testDescription: String { "\(stepMM) mm at phase \(phase) over \(rampS) s" }

        static let all: [Reseat] = [30.0, -30.0].flatMap { step in
            [0.2, 0.5, 0.85].flatMap { phase in
                [0.0, 0.15].map { Reseat(stepMM: step, phase: phase, rampS: $0) }
            }
        }
    }

    @Test(arguments: Reseat.all, [Sampling.sixtyHz, .thirtyHz])
    func aStepInTheTopSpoilsAtMostOneStroke(reseat: Reseat, sampling: Sampling) {
        let pace = Pace(rate: 110, depth: 50)
        let period = 60 / pace.rate
        let stepAt = (18 + reseat.phase) * period
        let truth = SyntheticSession.truth(steady(rate: pace.rate, depth: pace.depth))
        let samples = withStep(sampling.samples(pace, noiseMM: 1.5), of: reseat.stepMM, at: stepAt, over: reseat.rampS)
        let strokes = play(samples).compressions

        // A stroke is wrong when its depth is off, when it matches no true stroke, or when a true stroke is missing.
        var wrong = 0
        var lastWrongAt = -Double.infinity
        for bottom in truth.bottoms.dropLast() {
            let matches = strokes.filter { abs($0.tBottom - bottom.t) < period / 2 }
            if matches.count != 1 || abs(matches[0].depthMM - pace.depth) > 5 {
                wrong += 1
                lastWrongAt = bottom.t
            }
        }
        #expect(wrong <= 1, "\(wrong) strokes spoiled")
        #expect(lastWrongAt < stepAt + reseat.rampS + 3 * period, "still wrong at \(lastWrongAt), step at \(stepAt)")
    }

    @Test func aSuddenShiftWhileTheHandsAreNearStillSpoilsNothing() {
        let pace = Pace(rate: 110, depth: 50)
        let period = 60 / pace.rate
        let clean = Sampling.sixtyHz.samples(pace, noiseMM: 1.5)
        let original = play(clean).compressions
        // 0.35 is the deepest point, 0.85 the rest at the top.
        for phase in [0.35, 0.85] {
            let strokes = play(withStep(clean, of: 45, at: (18 + phase) * period, over: 0)).compressions
            #expect(strokes.count == original.count)
            for (stroke, before) in zip(strokes, original) {
                #expect(abs(stroke.depthMM - before.depthMM) < 5, "phase \(phase): \(before.depthMM) became \(stroke.depthMM)")
            }
        }
    }

    @Test func aSuddenShiftMidStrokeCostsThatStrokeOnlyOneSampleOfTravel() {
        let pace = Pace(rate: 110, depth: 50)
        let period = 60 / pace.rate
        let clean = Sampling.sixtyHz.samples(pace, noiseMM: 1.5)
        let original = play(clean).compressions
        let strokes = play(withStep(clean, of: 45, at: 18.2 * period, over: 0)).compressions
        #expect(strokes.count == original.count)
        let changes = zip(strokes, original).map { abs($0.depthMM - $1.depthMM) }
        #expect(changes.filter { $0 >= 5 }.count <= 1)
        #expect((changes.max() ?? 0) < 12)
    }

    // MARK: Odd input

    @Test func samplesThatDoNotMoveTimeForwardAreIgnored() {
        let samples = Sampling.sixtyHz.samples(Pace(rate: 110, depth: 50), seconds: 8)
        var clean = CompressionAnalyzer()
        var messy = CompressionAnalyzer()
        var cleanEvents: [SignalEvent] = []
        var messyEvents: [SignalEvent] = []
        for (index, sample) in samples.enumerated() {
            cleanEvents += clean.ingest(sample)
            messyEvents += messy.ingest(sample)
            if index % 5 == 0 {
                messyEvents += messy.ingest(HeightSample(t: sample.t, heightMM: 500))
                messyEvents += messy.ingest(HeightSample(t: sample.t - 0.01, heightMM: -500))
                messyEvents += messy.ingest(HeightSample(t: sample.t + 0.001, heightMM: .nan))
                messyEvents += messy.ingest(HeightSample(t: .nan, heightMM: 0))
            }
        }
        #expect(messyEvents == cleanEvents)
        #expect(messy.metrics == clean.metrics)
        #expect(messy.live == clean.live)
    }

    @Test func theSameInputAlwaysGivesTheSameOutput() {
        let samples = SyntheticSession.samples(SyntheticSession.demo, noiseMM: 2, seed: 9)
        let first = play(samples)
        let second = play(samples)
        #expect(first.events == second.events)
        #expect(first.analyzer.metrics == second.analyzer.metrics)
    }
}
