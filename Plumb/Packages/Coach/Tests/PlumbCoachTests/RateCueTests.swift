import PlumbContracts
import Testing
@testable import PlumbCoach

@Suite("Faster and slower")
struct RateCueTests {
    @Test("Rate too low gives faster and too high gives slower, once enough compressions have been seen",
          arguments: [(80.0, Cue.faster), (140.0, Cue.slower)])
    func outOfRange(ratePerMin: Double, cue: Cue) throws {
        var bench = Bench()
        let frames = bench.run(seconds: 20, .compressing(ratePerMin: ratePerMin))
        let judgedFrom = try #require(frames.first { $0.count >= 6 }).t
        let shownAt = judgedFrom + 2.5

        #expect(frames.filter { $0.t < shownAt }.isSilentAndBlank)
        #expect(frames.filter { $0.t >= shownAt }.allSatisfy { $0.show == cue })
        #expect(frames.utterances.first == Utterance(shownAt, cue))
        #expect(frames.utterances.allSatisfy { $0.cue == cue })
        expectHouseRules(frames)
    }

    @Test("Rate is not judged before the minimum count, however long a wrong rate is reported")
    func notBeforeTheMinimumCount() throws {
        var bench = Bench()
        let slow = Scene.compressing(ratePerMin: 80)
        while bench.count < 5 { bench.step(slow) }
        bench.run(seconds: 20, slow.withHandsStill)
        #expect(bench.frames.isSilentAndBlank)

        let onwards = bench.run(seconds: 6, slow)
        let sixthAt = try #require(onwards.first { $0.count >= 6 }).t
        let firstCue = try #require(onwards.first { $0.show != nil })
        #expect(firstCue.show == .faster)
        #expect(firstCue.t == sixthAt + 2.5)
    }

    @Test("Rate is coached whenever the rhythm is trusted, even if depth is not",
          arguments: [LockState.locked, .estimating, .rateOnly])
    func judgedWithoutDepthLock(lock: LockState) {
        var bench = Bench()
        let frames = bench.run(seconds: 20, .compressing(ratePerMin: 80, lock: lock))
        #expect(frames.last?.show == .faster)
        #expect(frames.utterances.first?.cue == .faster)
    }

    @Test("With the signal lost, rate is neither shown nor said")
    func notJudgedWhenLost() {
        var bench = Bench()
        let frames = bench.run(seconds: 30, .compressing(ratePerMin: 80, lock: .lost))
        #expect(frames.isSilentAndBlank)
    }

    @Test("A rate cue on screen is withdrawn while the rate cannot be judged, and returns when it can")
    func withdrawnWhileUnjudged() {
        var bench = Bench()
        let slow = Scene.compressing(ratePerMin: 80)
        #expect(bench.run(seconds: 10, slow).last?.show == .faster)

        let lost = bench.run(seconds: 2, .compressing(ratePerMin: 80, lock: .lost))
        #expect(lost.isSilentAndBlank)
        #expect(bench.step(slow).show == .faster)

        var noRate = slow
        noRate.ratePerMin = nil
        #expect(bench.run(seconds: 2, noRate).isSilentAndBlank)
        #expect(bench.step(slow).show == .faster)
    }

    @Test("A rate fault is cleared by a pause and has to be earned again from a fresh count")
    func clearedByAPause() throws {
        var bench = Bench()
        let slow = Scene.compressing(ratePerMin: 80)
        #expect(bench.run(seconds: 10, slow).last?.show == .faster)

        let paused = bench.run(seconds: 1, .paused(ratePerMin: 80))
        #expect(paused.allSatisfy { $0.show == .pushNow })
        let countAtPause = bench.count

        let resumed = bench.run(seconds: 12, slow)
        #expect(resumed.first?.show == nil)
        let judgedFrom = try #require(resumed.first { $0.count - countAtPause >= 6 }).t
        #expect(resumed.filter { $0.t < judgedFrom + 2.5 }.allSatisfy { $0.show == nil })
        #expect(resumed.first { $0.show != nil }?.show == .faster)
        #expect(resumed.first { $0.show != nil }?.t == judgedFrom + 2.5)
    }

    @Test("A pause that began and ended between two looks still clears the rate fault")
    func clearedByAPauseSeenOnlyInEvents() {
        var bench = Bench()
        let slow = Scene.compressing(ratePerMin: 80)
        #expect(bench.run(seconds: 10, slow).last?.show == .faster)
        let countAtPause = bench.count

        let missedPause: [SignalEvent] = [
            .pauseStarted(at: bench.now),
            .pauseEnded(at: bench.now + 2, duration: 2),
        ]
        #expect(bench.step(slow, events: missedPause).show == nil)

        let resumed = bench.run(seconds: 12, slow)
        let back = resumed.first { $0.show == .faster }
        #expect((back?.count ?? 0) - countAtPause >= 6)
    }

    @Test("A rate cue stays until the rate is back inside the target by the dead band",
          arguments: [(80.0, Cue.faster, 101.0, 103.0), (140.0, Cue.slower, 119.0, 117.0)])
    func heldUntilClearlyFixed(faulty: Double, cue: Cue, barelyIn: Double, clearlyIn: Double) {
        var bench = Bench()
        #expect(bench.run(seconds: 10, .compressing(ratePerMin: faulty)).last?.show == cue)
        #expect(bench.run(seconds: 5, .compressing(ratePerMin: barelyIn)).allSatisfy { $0.show == cue })
        #expect(bench.step(.compressing(ratePerMin: clearlyIn)).show == nil)
    }

    @Test("Overshooting from too slow to too fast swaps the cue only after the new fault has persisted")
    func overshoot() {
        var bench = Bench()
        #expect(bench.run(seconds: 10, .compressing(ratePerMin: 80)).last?.show == .faster)

        let overshootAt = bench.now + Bench.tick
        let tooFast = bench.run(seconds: 10, .compressing(ratePerMin: 140))
        #expect(tooFast.showChanges == [nil, .slower])
        #expect(tooFast.first { $0.show == .slower }?.t == overshootAt + 2.5)
        expectHouseRules(bench.frames)
    }

    @Test("Rate inside the dead band is never a cue, and hovering at the threshold does not flicker")
    func deadBandAndHysteresis() {
        var inside = Bench()
        #expect(inside.run(seconds: 120, .compressing(ratePerMin: 100 - 1.5)).isSilentAndBlank)

        var hovering = Bench()
        let frames = hovering.run(seconds: 30) { tick in
            Scene(cadence: 97, ratePerMin: tick.isMultiple(of: 2) ? 96.5 : 97.5)
        }
        #expect(frames.showChanges == [nil, .faster])
    }
}
