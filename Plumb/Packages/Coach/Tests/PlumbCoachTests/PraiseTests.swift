import PlumbContracts
import Testing
@testable import PlumbCoach

@Suite("Good compressions")
struct PraiseTests {
    @Test("After push harder was said and depth recovers for the required compressions: good is shown briefly and said exactly once")
    func afterAFix() throws {
        var bench = Bench()
        bench.run(seconds: 5, .compressing(depthMM: 40))
        #expect(bench.frames.utterances.map(\.cue) == [.pushHarder])

        let recovered = bench.run(seconds: 20, .compressing(depthMM: 56))
        let fixedAtCount = try #require(recovered.first).count
        #expect(recovered.first?.show == nil)

        let praised = try #require(recovered.first { $0.speak != nil })
        #expect(praised.speak == .good)
        #expect(praised.count - fixedAtCount == 4)
        #expect(recovered.utterances == [Utterance(praised.t, .good)])

        #expect(recovered.filter { $0.t < praised.t }.allSatisfy { $0.show == nil })
        #expect(recovered.filter { $0.t >= praised.t && $0.t < praised.t + 2 }.allSatisfy { $0.show == .good })
        #expect(recovered.filter { $0.t >= praised.t + 2 }.allSatisfy { $0.show == nil })
        expectHouseRules(bench.frames)
    }

    @Test("Long steady good compressions: good is said once per long interval and shown only briefly each time")
    func steadyWork() throws {
        var bench = Bench()
        let frames = bench.run(seconds: 300, .compressing())
        let onTargetFrom = try #require(frames.first { $0.count >= 6 }).t

        let expected = stride(from: onTargetFrom + 30, to: 300, by: 30).map { Utterance($0, .good) }
        #expect(frames.utterances == expected)
        #expect(expected.count == 9)

        let secondsShowingGood = Double(frames.filter { $0.show == .good }.count) * Bench.tick
        #expect(secondsShowingGood == Double(expected.count) * 2)
        #expect(frames.allSatisfy { $0.show == nil || $0.show == .good })
    }

    @Test("Good is never said or shown while a fault is showing")
    func neverDuringAFault() {
        var bench = Bench()
        let frames = bench.run(seconds: 120, .compressing(ratePerMin: 80))
        #expect(frames.allSatisfy { $0.speak != .good && $0.show != .good })
        #expect(frames.last?.show == .faster)
    }

    @Test("Good is never given on the strength of a depth that cannot be trusted",
          arguments: [LockState.estimating, .rateOnly, .lost])
    func neverWithoutTrustedDepth(lock: LockState) {
        var bench = Bench()
        let frames = bench.run(seconds: 120, .compressing(lock: lock))
        #expect(frames.isSilentAndBlank)
    }

    @Test("A short spell of untrusted depth does not restart the long interval, but a long one does")
    func blindSpells() {
        var forgiven = Bench()
        forgiven.run(seconds: 20, .compressing())
        forgiven.run(seconds: 2, .compressing(lock: .estimating))
        forgiven.run(seconds: 20, .compressing())
        #expect(forgiven.frames.utterances.map(\.cue) == [.good])

        var restarted = Bench()
        restarted.run(seconds: 20, .compressing())
        restarted.run(seconds: 4, .compressing(lock: .estimating))
        restarted.run(seconds: 20, .compressing())
        #expect(restarted.frames.utterances.isEmpty)
    }

    @Test("After a pause, good waits until the restarted compressions have been judged and found on target")
    func afterAPause() throws {
        var bench = Bench()
        bench.run(seconds: 10, .compressing())
        bench.run(seconds: 2, .paused())
        let countAtPause = bench.count

        let resumed = bench.run(seconds: 15, .compressing())
        let praised = try #require(resumed.first { $0.speak == .good })
        // Six compressions before rate can be judged at all, then four judged ones on target.
        #expect(praised.count - countAtPause == 10)
        #expect(resumed.utterances.count == 1)
    }

    @Test("Praise on screen gives way at once to a pause and does not come back afterwards")
    func withdrawnByAPause() throws {
        var bench = Bench()
        bench.run(seconds: 5, .compressing(depthMM: 40))
        let praised = bench.run(.compressing(depthMM: 56), until: { $0.speak == .good })
        try #require(praised != nil)

        #expect(bench.step(.paused()).show == .pushNow)
        #expect(bench.step(.compressing(depthMM: 56)).show == nil)
    }

    @Test("Praise on screen is withdrawn when the signal is lost and does not come back with it")
    func withdrawnByALostSignal() throws {
        var bench = Bench()
        bench.run(seconds: 5, .compressing(depthMM: 40))
        let praised = bench.run(.compressing(depthMM: 56), until: { $0.speak == .good })
        try #require(praised != nil)

        #expect(bench.step(.compressing(depthMM: 56, lock: .lost)).show == nil)
        #expect(bench.step(.compressing(depthMM: 56)).show == nil)
    }

    @Test("Praise never stays up over a pause, even one kept off screen while the signal settles")
    func withdrawnByAnUnsettledPause() throws {
        var bench = Bench()
        bench.run(seconds: 5, .compressing(depthMM: 40))
        let praised = bench.run(.compressing(depthMM: 56), until: { $0.speak == .good })
        try #require(praised != nil)

        let blink: [SignalEvent] = [.lockChanged(.lost, at: bench.now), .lockChanged(.locked, at: bench.now)]
        #expect(bench.step(.paused(), events: blink).show == nil)
    }

    @Test("A marginal spell earns no cue, but it does restart the long interval")
    func marginalSpellRestartsTheInterval() {
        var bench = Bench()
        bench.run(seconds: 20, .compressing())
        bench.run(seconds: 5, .compressing(depthMM: 48))
        bench.run(seconds: 20, .compressing())
        #expect(bench.frames.isSilentAndBlank)
    }

    @Test("A pause ends the stretch of good work even when a lost signal keeps it off screen")
    func hiddenPauseRestartsTheInterval() {
        // Rate is judged from the first stroke here, so only the pause itself can break the stretch.
        var config = CuePolicy.Config()
        config.minCompressionsForRate = 1
        var bench = Bench(policy: CuePolicy(config: config))
        bench.run(seconds: 20, .compressing())
        bench.run(seconds: 0.5, .paused(lock: .lost))
        bench.run(seconds: 20, .compressing())
        #expect(bench.frames.isSilentAndBlank)
    }

    @Test("Marginal work earns no praise: in the dead band below the target, or outside the rate range")
    func noPraiseForMarginalWork() {
        var shallowish = Bench()
        #expect(shallowish.run(seconds: 120, .compressing(depthMM: 48)).isSilentAndBlank)

        var slowish = Bench()
        #expect(slowish.run(seconds: 120, .compressing(ratePerMin: 98)).isSilentAndBlank)
    }
}
