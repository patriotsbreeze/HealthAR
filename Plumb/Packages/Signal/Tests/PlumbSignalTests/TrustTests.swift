import Foundation
import PlumbContracts
import Testing
@testable import PlumbSignal

@Suite struct TrustTests {
    /// Steady compressions whose quality is set sample by sample.
    private func compressing(seconds: Double, sampleHz: Double = 60,
                             quality: (TimeInterval) -> Double) -> [HeightSample] {
        SyntheticSession.samples(steady(rate: 110, depth: 50, seconds: seconds), sampleHz: sampleHz,
                                 noiseMM: 2, seed: 6).map {
            HeightSample(t: $0.t, heightMM: $0.heightMM, quality: quality($0.t))
        }
    }

    @Test(arguments: [(0.9, LockState.locked), (0.45, .estimating), (0.1, .rateOnly)])
    func steadyQualitySettlesOnItsLock(quality: Double, expected: LockState) {
        let run = play(compressing(seconds: 6) { _ in quality })
        #expect(run.analyzer.metrics.lock == expected)
        #expect(run.analyzer.live.lock == expected)
        #expect(run.locks == (expected == .rateOnly ? [.rateOnly] : [.rateOnly, expected]))
    }

    @Test func theBandEdgesBelongToTheBetterLock() {
        #expect(play(compressing(seconds: 4) { _ in 0.6 }).analyzer.metrics.lock == .locked)
        #expect(play(compressing(seconds: 4) { _ in 0.3 }).analyzer.metrics.lock == .estimating)
        #expect(play(compressing(seconds: 4) { _ in 0.29 }).analyzer.metrics.lock == .rateOnly)
    }

    @Test func gainingTrustTakesAboutASecondAndLosingItIsQuicker() throws {
        let run = play(compressing(seconds: 8) { $0 < 4 ? 0.9 : 0.1 })
        let changes = run.events.compactMap { event -> (LockState, TimeInterval)? in
            if case .lockChanged(let lock, let at) = event { (lock, at) } else { nil }
        }
        #expect(changes.map(\.0) == [.rateOnly, .locked, .rateOnly])
        let gained = changes[1].1
        #expect(gained >= 0.9 && gained <= 1.2, "locked after \(gained) s")
        let lost = changes[2].1 - 4
        #expect(lost >= 0.2 && lost <= 0.5, "trust dropped \(lost) s after quality did")
        #expect(lost < gained)
    }

    @Test func briefDipsAndBriefFlashesChangeNothing() {
        // Locked, then a tenth of a second of poor quality once a second.
        let dips = play(compressing(seconds: 10) { $0 > 2 && $0.truncatingRemainder(dividingBy: 1) > 0.9 ? 0.05 : 0.9 })
        #expect(dips.locks == [.rateOnly, .locked])

        // Poor quality with a tenth of a second of good quality once a second.
        let flashes = play(compressing(seconds: 10) { $0.truncatingRemainder(dividingBy: 1) > 0.9 ? 0.95 : 0.1 })
        #expect(flashes.locks == [.rateOnly])
    }

    @Test func mostlyGoodQualityStillEarnsTrustOnlyALittleLater() throws {
        let run = play(compressing(seconds: 10) { $0.truncatingRemainder(dividingBy: 1) > 0.9 ? 0.05 : 0.9 })
        #expect(run.locks == [.rateOnly, .locked])
        let lockedAt = try #require(run.events.compactMap { event -> TimeInterval? in
            if case .lockChanged(.locked, let at) = event { at } else { nil }
        }.first)
        #expect(lockedAt > 1.0 && lockedAt < 3.0)
    }

    @Test func qualityHoveringAtAThresholdDoesNotFlicker() {
        var rng = SplitMix64(seed: 3)
        let fromBelow = play(compressing(seconds: 12) { _ in 0.6 + 0.08 * (rng.nextUnit() - 0.5) })
        #expect(fromBelow.locks == [.rateOnly, .estimating])

        let fromAbove = play(compressing(seconds: 12) { $0 < 3 ? 0.9 : 0.6 + 0.08 * (rng.nextUnit() - 0.5) })
        #expect(fromAbove.locks == [.rateOnly, .locked, .estimating])
    }

    @Test func eachCompressionCarriesTheLockAtItsDeepestPoint() throws {
        let run = play(compressing(seconds: 8) { $0 < 4 ? 0.9 : 0.45 })
        let changes = run.events.compactMap { event -> (LockState, TimeInterval)? in
            if case .lockChanged(let lock, let at) = event { (lock, at) } else { nil }
        }
        #expect(changes.map(\.0) == [.rateOnly, .locked, .estimating])
        for stroke in run.compressions {
            let expected = changes.last { $0.1 <= stroke.tBottom }?.0 ?? .lost
            #expect(stroke.lock == expected, "stroke at \(stroke.tBottom)")
        }
        #expect(Set(run.compressions.map(\.lock)) == [.rateOnly, .locked, .estimating])
    }

    @Test(arguments: [0.1, 0.45])
    func withoutFullTrustStrokesCountAndGiveRateButNoDepth(quality: Double) throws {
        let run = play(compressing(seconds: 10) { _ in quality })
        let truth = SyntheticSession.truth(steady(rate: 110, depth: 50, seconds: 10))
        #expect(abs(run.compressions.count - truth.bottoms.count) <= 1)
        #expect(abs(try #require(run.analyzer.metrics.ratePerMin) - 110) <= 2)
        #expect(run.analyzer.metrics.depthMM == nil)
        #expect(run.analyzer.metrics.depthSpreadMM == nil)
        #expect(run.compressions.allSatisfy { $0.lock != .locked })
    }

    @Test func depthFadesOutOnceTheLatestStrokesAreAllUntrusted() throws {
        let run = play(compressing(seconds: 12) { $0 < 6 ? 0.9 : 0.1 })
        let firstUntrusted = try #require(run.compressions.firstIndex { $0.tBottom > 6.5 && $0.lock == .rateOnly })
        #expect(run.metricsAfterStroke[firstUntrusted].depthMM != nil)
        #expect(run.metricsAfterStroke[firstUntrusted + 3].depthMM != nil)
        #expect(run.metricsAfterStroke[firstUntrusted + 4].depthMM == nil)
    }

    // MARK: Loss of signal

    @Test func aSecondWithoutSamplesIsLostAndIsNotAPause() throws {
        let all = compressing(seconds: 14) { _ in 0.9 }
        let samples = all.filter { $0.t < 6 || $0.t >= 7.2 }
        let lastSeen = try #require(samples.last { $0.t < 6 }).t
        let run = play(samples)

        let changes = run.events.compactMap { event -> (LockState, TimeInterval)? in
            if case .lockChanged(let lock, let at) = event { (lock, at) } else { nil }
        }
        #expect(changes.map(\.0) == [.rateOnly, .locked, .lost, .rateOnly, .locked])
        #expect(abs(changes[2].1 - (lastSeen + 0.5)) < 1e-9)
        let noticedAt = try #require(run.reportTime { $0 == .lockChanged(.lost, at: changes[2].1) })
        #expect(noticedAt <= lastSeen + 0.5 + 0.2 + 1e-9, "a tick notices the loss, not the next sample")
        #expect(changes[3].1 == 7.2)

        #expect(run.pauseStarts.isEmpty)
        #expect(run.pauseEnds.isEmpty)
        #expect(run.analyzer.metrics.handsOnFraction == 1)
    }

    @Test func aLongLossIsStillNotAPause() throws {
        let all = compressing(seconds: 20) { _ in 0.9 }
        let samples = all.filter { $0.t < 6 || $0.t >= 12 }
        let run = play(samples)
        #expect(run.locks.contains(.lost))
        #expect(run.pauseStarts.isEmpty)
        #expect(run.analyzer.metrics.handsOnFraction == 1)
        #expect(!run.analyzer.metrics.isPaused)

        let firstBack = try #require(run.compressions.first { $0.tBottom > 12 })
        #expect(firstBack.intervalS == nil, "the gap across a loss is not an interval between compressions")
        #expect(firstBack.lock == .rateOnly)
    }

    @Test func whileLostMetricsSayLostAndShowNoStaleNumbers() {
        let samples = compressing(seconds: 6) { _ in 0.9 }
        let run = play(samples, until: 9)
        let metrics = run.analyzer.metrics
        #expect(metrics.lock == .lost)
        #expect(metrics.ratePerMin == nil)
        #expect(metrics.depthMM == nil)
        #expect(!metrics.isPaused)
        #expect(metrics.t == 9)
        #expect(run.analyzer.live.lock == .lost)
        #expect(run.analyzer.live.currentDepthMM == 0)
        #expect(run.pauseStarts.isEmpty)
    }

    @Test func lossIsNoticedEvenWithoutTicks() throws {
        let all = compressing(seconds: 10) { _ in 0.9 }
        var analyzer = CompressionAnalyzer()
        var events: [SignalEvent] = []
        for sample in all where sample.t < 4 || sample.t >= 6 {
            events += analyzer.ingest(sample)
        }
        let lastSeen = try #require(all.last { $0.t < 4 }).t
        let lostIndex = try #require(events.firstIndex(of: .lockChanged(.lost, at: lastSeen + 0.5)))
        #expect(events[lostIndex + 1] == .lockChanged(.rateOnly, at: 6))
    }

    @Test func aPauseInProgressIsFrozenWhileTheSignalIsLost() throws {
        // Compress, stop, lose the signal for four seconds mid-pause, come back still, then compress again.
        let segments: [SyntheticSegment] = [wholeStrokes(11, rate: 110, depth: 50), .pause(11),
                                            wholeStrokes(6, rate: 110, depth: 50)]
        let truth = SyntheticSession.truth(segments)
        let lastBefore = truth.bottoms[10].t
        let firstAfter = truth.bottoms[11].t
        let all = SyntheticSession.samples(segments, noiseMM: 2, seed: 8)
        let lostFrom = lastBefore + 4
        let samples = all.filter { $0.t < lostFrom || $0.t >= lostFrom + 4 }
        let lastSeen = try #require(samples.last { $0.t < lostFrom }).t

        var analyzer = CompressionAnalyzer()
        var events: [SignalEvent] = []
        var pauseWhenLost = 0.0
        var pauseOnReturn = 0.0
        for sample in samples {
            if sample.t >= lostFrom + 4, pauseOnReturn == 0 {
                events += analyzer.tick(now: lostFrom + 3.9)
                pauseWhenLost = analyzer.metrics.pauseSeconds
                events += analyzer.ingest(sample)
                pauseOnReturn = analyzer.metrics.pauseSeconds
            } else {
                events += analyzer.ingest(sample)
            }
        }
        // Seen time stops half a second after the last sample and starts again with the next one.
        let seenBeforeLoss = lastSeen + 0.5 - lastBefore
        #expect(abs(pauseWhenLost - seenBeforeLoss) < 0.01)
        #expect(abs(pauseOnReturn - seenBeforeLoss) < 0.01)

        let starts = events.filter { if case .pauseStarted = $0 { true } else { false } }
        #expect(starts.count == 1)
        let ends = events.compactMap { event -> Double? in
            if case .pauseEnded(_, let duration) = event { duration } else { nil }
        }
        #expect(ends.count == 1)
        let blind = (lostFrom + 4) - (lastSeen + 0.5)
        #expect(abs(try #require(ends.first) - (firstAfter - lastBefore - blind)) <= 0.3,
                "time the analyzer could not see is not counted as pause")
    }
}
