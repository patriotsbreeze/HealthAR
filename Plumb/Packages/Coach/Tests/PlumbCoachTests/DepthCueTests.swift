import PlumbContracts
import Testing
@testable import PlumbCoach

@Suite("Push harder")
struct DepthCueTests {
    private let shallow = Scene.compressing(depthMM: 40)

    @Test("Shallow and locked: shown only after the persistence window, said once, then again only after the same-cue gap")
    func shallowAndLocked() throws {
        var bench = Bench()
        let frames = bench.run(seconds: 30, shallow)
        let firstCompressionAt = try #require(frames.first { $0.count > 0 }).t
        let shownAt = firstCompressionAt + 2.5

        #expect(frames.filter { $0.t < shownAt }.isSilentAndBlank)
        #expect(frames.filter { $0.t >= shownAt }.allSatisfy { $0.show == .pushHarder })
        #expect(frames.utterances == [
            Utterance(shownAt, .pushHarder),
            Utterance(shownAt + 12, .pushHarder),
            Utterance(shownAt + 24, .pushHarder),
        ])
        expectHouseRules(frames)
    }

    @Test("Still shallow after the gap, but it is not said again until enough new compressions have happened")
    func repeatWaitsForNewCompressions() throws {
        var bench = Bench()
        bench.run(seconds: 4, shallow)
        let first = try #require(bench.frames.last { $0.speak == .pushHarder })

        // Far longer than the same-cue gap, with the fault still on screen but no new strokes to judge.
        let stalled = bench.run(seconds: 13, shallow.withHandsStill)
        #expect(stalled.allSatisfy { $0.show == .pushHarder && $0.speak == nil })

        let resumed = bench.run(seconds: 5, shallow)
        let second = try #require(resumed.first { $0.speak != nil })
        #expect(second.speak == .pushHarder)
        #expect(second.count - first.count == 4)
    }

    @Test("Shallow while estimating, rate only or lost: never shown, never said",
          arguments: [LockState.estimating, .rateOnly, .lost])
    func neverJudgedWithoutLock(lock: LockState) {
        var bench = Bench()
        let frames = bench.run(seconds: 30, .compressing(depthMM: 30, lock: lock))
        #expect(frames.isSilentAndBlank)
    }

    @Test("A cue already on screen is withdrawn the moment depth stops being trusted, and returns with the lock",
          arguments: [LockState.estimating, .rateOnly, .lost])
    func withdrawnWhenLockDrops(lock: LockState) {
        var bench = Bench()
        #expect(bench.run(seconds: 5, shallow).last?.show == .pushHarder)

        let untrusted = bench.run(seconds: 2, .compressing(depthMM: 40, lock: lock))
        #expect(untrusted.allSatisfy { $0.show == nil && $0.speak == nil })

        #expect(bench.step(shallow).show == .pushHarder)
    }

    @Test("Depth exactly at target minus half the dead band: never a cue of any kind")
    func insideTheDeadBand() {
        var bench = Bench()
        let frames = bench.run(seconds: 120, .compressing(depthMM: 50 - 1.5))
        #expect(frames.isSilentAndBlank)
    }

    @Test("Depth exactly at the edge of the dead band is not yet a fault")
    func exactlyAtTheTripPoint() {
        var bench = Bench()
        let frames = bench.run(seconds: 60, .compressing(depthMM: 47))
        #expect(frames.isSilentAndBlank)
    }

    @Test("Hovering either side of the fault threshold on alternate looks: the cue comes on once and stays")
    func hoveringAtTheTripPoint() {
        var bench = Bench()
        let frames = bench.run(seconds: 30) { tick in
            .compressing(depthMM: tick.isMultiple(of: 2) ? 46.5 : 47.5)
        }
        #expect(frames.showChanges == [nil, .pushHarder])
    }

    @Test("Hovering either side of the all-clear threshold on alternate looks: the cue goes off once and stays off")
    func hoveringAtTheClearPoint() {
        var bench = Bench()
        bench.run(seconds: 5, shallow)
        bench.run(seconds: 10) { tick in
            .compressing(depthMM: tick.isMultiple(of: 2) ? 52.5 : 53.5)
        }
        // The fix is followed by its praise; what matters is that PUSH HARDER never comes back.
        #expect(bench.frames.showChanges == [nil, .pushHarder, nil, .good, nil])
    }

    @Test("Back inside the target but not by the dead band: the cue stays until the fix is clear")
    func heldUntilClearlyFixed() {
        var bench = Bench()
        bench.run(seconds: 5, shallow)
        let barelyIn = bench.run(seconds: 5, .compressing(depthMM: 51))
        #expect(barelyIn.allSatisfy { $0.show == .pushHarder })

        #expect(bench.step(.compressing(depthMM: 53)).show == nil)
    }

    @Test("One stray shallow reading among near-target ones is not a fault")
    func singleDipIsForgotten() {
        var bench = Bench()
        bench.run(seconds: 5, .compressing(depthMM: 55))
        bench.step(.compressing(depthMM: 40))
        bench.run(seconds: 20, .compressing(depthMM: 48))
        #expect(bench.frames.allSatisfy { $0.show != .pushHarder && $0.speak != .pushHarder })
    }

    @Test("Targets are honoured: what is shallow for an adult can be deep enough for another target")
    func customTargets() {
        var targets = Targets.adult
        targets.depthMinMM = 35
        var bench = Bench(policy: CuePolicy(targets: targets))
        let frames = bench.run(seconds: 20, shallow)
        #expect(frames.allSatisfy { $0.show != .pushHarder })
    }
}
