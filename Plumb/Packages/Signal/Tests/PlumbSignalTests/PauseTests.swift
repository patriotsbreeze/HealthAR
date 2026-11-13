import Foundation
import PlumbContracts
import Testing
@testable import PlumbSignal

@Suite struct PauseTests {
    /// Compressions, a five second stop, compressions again, then a short stop. No stroke is cut short.
    static let stopAndGo: [SyntheticSegment] = [
        .pause(1),
        wholeStrokes(15, rate: 110, depth: 50),
        .pause(5),
        wholeStrokes(15, rate: 115, depth: 52),
        .pause(1),
    ]

    private func gap(in truth: SyntheticSession.Truth) -> (lastBefore: TimeInterval, firstAfter: TimeInterval) {
        (truth.bottoms[14].t, truth.bottoms[15].t)
    }

    @Test(arguments: [Sampling.sixtyHz, .thirtyHz])
    func aPauseIsReportedPromptlyAndDatedFromTheLastDeepestPoint(sampling: Sampling) throws {
        let truth = SyntheticSession.truth(Self.stopAndGo)
        let (lastBefore, firstAfter) = gap(in: truth)
        let hz: Double = sampling == .thirtyHz ? 30 : 60
        let run = play(SyntheticSession.samples(Self.stopAndGo, sampleHz: hz, noiseMM: 2, seed: 3))

        #expect(run.pauseStarts.count == 1)
        let startedAt = try #require(run.pauseStarts.first)
        #expect(abs(startedAt - lastBefore) <= 0.1)

        let noticedAt = try #require(run.reportTime { if case .pauseStarted = $0 { true } else { false } })
        let due = lastBefore + 2.0
        #expect(noticedAt > due - 0.1)
        #expect(noticedAt <= due + 0.3, "pause noticed \(noticedAt - due) s after it was due")

        #expect(run.pauseEnds.count == 1)
        let ended = try #require(run.pauseEnds.first)
        #expect(abs(ended.at - firstAfter) <= 0.1)
        #expect(abs(ended.duration - (firstAfter - lastBefore)) <= 0.3)
    }

    @Test func thePauseEndsJustBeforeTheCompressionThatEndsIt() throws {
        let run = play(SyntheticSession.samples(Self.stopAndGo, noiseMM: 2, seed: 3))
        let endIndex = try #require(run.events.firstIndex { if case .pauseEnded = $0 { true } else { false } })
        guard case .pauseEnded(let endedAt, _) = run.events[endIndex],
              case .compression(let stroke) = run.events[endIndex + 1]
        else {
            Issue.record("the event after pauseEnded was not a compression")
            return
        }
        #expect(stroke.tBottom == endedAt)
        #expect(stroke.intervalS == nil)
        #expect(stroke.index == 16)
        #expect(run.reported[endIndex].at == run.reported[endIndex + 1].at)
    }

    @Test func metricsCountThePauseFromTheLastCompression() throws {
        let truth = SyntheticSession.truth(Self.stopAndGo)
        let (lastBefore, firstAfter) = gap(in: truth)
        let samples = SyntheticSession.samples(Self.stopAndGo, noiseMM: 2, seed: 3)
        var analyzer = CompressionAnalyzer()

        for sample in samples where sample.t <= lastBefore + 1.5 {
            _ = analyzer.ingest(sample)
        }
        #expect(!analyzer.metrics.isPaused)
        #expect(analyzer.metrics.pauseSeconds == 0)
        #expect(analyzer.metrics.ratePerMin != nil)

        for sample in samples where sample.t > lastBefore + 1.5 && sample.t <= lastBefore + 4 {
            _ = analyzer.ingest(sample)
        }
        let paused = analyzer.metrics
        #expect(paused.isPaused)
        #expect(abs(paused.pauseSeconds - 4) < 0.15)
        #expect(abs(try #require(paused.secondsSinceLastCompression) - 4) < 0.15)
        #expect(paused.ratePerMin == nil, "a rate must not be shown while nobody is compressing")
        #expect(paused.depthMM == nil)
        #expect(paused.count == 15)

        for sample in samples where sample.t > lastBefore + 4 && sample.t <= firstAfter + 0.4 {
            _ = analyzer.ingest(sample)
        }
        #expect(!analyzer.metrics.isPaused)
        #expect(analyzer.metrics.pauseSeconds == 0)
        #expect(analyzer.metrics.count == 16)
    }

    @Test func rateComesBackOnlyAfterTwoNewIntervals() {
        let run = play(SyntheticSession.samples(Self.stopAndGo, noiseMM: 2, seed: 3))
        #expect(run.metricsAfterStroke[14].ratePerMin != nil)
        #expect(run.metricsAfterStroke[15].ratePerMin == nil)
        #expect(run.metricsAfterStroke[16].ratePerMin == nil)
        #expect(run.metricsAfterStroke[17].ratePerMin != nil)
        #expect(run.compressions[16].intervalS != nil)
    }

    @Test func aPauseIsNoticedByTickAloneWhenSamplesKeepComing() throws {
        // Samples at a trickle, well under the loss threshold apart, so only ticks see the threshold pass.
        let truth = SyntheticSession.truth(Self.stopAndGo)
        let (lastBefore, firstAfter) = gap(in: truth)
        let samples = SyntheticSession.samples(Self.stopAndGo, noiseMM: 1, seed: 3).filter { sample in
            sample.t < lastBefore + 0.5 || sample.t > firstAfter - 1 || Int((sample.t * 60).rounded()) % 24 == 0
        }
        let run = play(samples, tickEvery: 0.1)
        let noticedAt = try #require(run.reportTime { if case .pauseStarted = $0 { true } else { false } })
        #expect(noticedAt > lastBefore + 2.0)
        #expect(noticedAt <= lastBefore + 2.3)
        #expect(run.locks.filter { $0 == .lost }.isEmpty)
    }

    @Test func handsOnFractionMatchesTheDemoSession() throws {
        let demo = SyntheticSession.demo
        let truth = SyntheticSession.truth(demo)
        let samples = SyntheticSession.samples(demo, noiseMM: 2, seed: 5)
        let end = try #require(samples.last).t
        let first = try #require(truth.bottoms.first).t

        var pausedS = 0.0
        for (earlier, later) in zip(truth.bottoms, truth.bottoms.dropFirst()) where later.t - earlier.t > 2.0 {
            pausedS += later.t - earlier.t
        }
        let trueFraction = 1 - pausedS / (end - first)

        let run = play(samples)
        let fraction = try #require(run.analyzer.metrics.handsOnFraction)
        #expect(abs(fraction - trueFraction) <= 0.03, "hands-on \(fraction), truly \(trueFraction)")
        #expect(abs(try #require(run.analyzer.metrics.firstCompressionAt) - first) <= 0.05)
    }

    @Test func theDemoSessionTellsItsStory() throws {
        let demo = SyntheticSession.demo
        let truth = SyntheticSession.truth(demo)
        let still = try #require(truth.stillSpans.last)
        let lastBefore = try #require(truth.bottoms.last { $0.t < still.lowerBound }).t
        let firstAfter = try #require(truth.bottoms.first { $0.t > still.upperBound }).t
        let run = play(SyntheticSession.samples(demo, noiseMM: 2, seed: 5))

        #expect(abs(run.compressions.count - truth.bottoms.count) <= 1)
        #expect(run.pauseStarts.count == 1)
        #expect(abs(try #require(run.pauseStarts.first) - lastBefore) <= 0.1)
        let ended = try #require(run.pauseEnds.first)
        #expect(abs(ended.duration - (firstAfter - lastBefore)) <= 0.3)

        let shallow = run.compressions.filter { $0.tBottom < 10 && $0.lock == .locked }.map(\.depthMM)
        let corrected = run.compressions.filter { $0.tBottom > 26 }.map(\.depthMM)
        #expect(abs(median(shallow) - 38) <= 3)
        #expect(abs(median(corrected) - 55) <= 3)
    }

    @Test func handsOnIsOneBeforeAnyPauseAndNilBeforeAnyCompression() {
        var analyzer = CompressionAnalyzer()
        _ = analyzer.tick(now: 1)
        #expect(analyzer.metrics.handsOnFraction == nil)
        #expect(analyzer.metrics.firstCompressionAt == nil)
        #expect(analyzer.metrics.secondsSinceLastCompression == nil)

        let run = play(Sampling.sixtyHz.samples(Pace(rate: 110, depth: 50), seconds: 10))
        #expect(run.analyzer.metrics.handsOnFraction == 1)
        #expect(run.pauseStarts.isEmpty)
    }
}
