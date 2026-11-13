import PlumbContracts
import Testing
@testable import PlumbCoach

@Suite("What may be judged")
struct SightTests {
    private func sight(lock: LockState = .locked, isPaused: Bool = false, sincePause: Int = 20,
                       depthMM: Double? = 55, ratePerMin: Double? = 110) -> Sight {
        let metrics = Metrics(lock: lock, count: 20, ratePerMin: ratePerMin, depthMM: depthMM,
                              isPaused: isPaused, pauseSeconds: isPaused ? 2 : 0)
        return Sight(metrics: metrics, compressionsSincePause: sincePause, minCompressionsForRate: 6)
    }

    @Test("Depth may be judged only when the lock is locked", arguments: LockState.allCases)
    func depthNeedsFullTrust(lock: LockState) {
        #expect(sight(lock: lock).depthMM == (lock == .locked ? 55 : nil))
    }

    @Test("Rate may be judged with any signal at all, but not with none", arguments: LockState.allCases)
    func rateNeedsASignal(lock: LockState) {
        #expect(sight(lock: lock).ratePerMin == (lock == .lost ? nil : 110))
    }

    @Test("Rate may not be judged until enough compressions have followed the start or the last pause")
    func rateNeedsEnoughCompressions() {
        #expect(sight(sincePause: 5).ratePerMin == nil)
        #expect(sight(sincePause: 6).ratePerMin == 110)
        #expect(sight(sincePause: 5).depthMM == 55)
    }

    @Test("Nothing may be judged during a pause, whatever the rolling numbers still say")
    func nothingDuringAPause() {
        let paused = sight(isPaused: true)
        #expect(paused.depthMM == nil)
        #expect(paused.ratePerMin == nil)
    }

    @Test("On target needs both depth and rate judged and inside the target; the dead band does not count")
    func quality() {
        let adult = Targets.adult
        #expect(sight().quality(against: adult) == .onTarget)
        #expect(sight(depthMM: 50, ratePerMin: 100).quality(against: adult) == .onTarget)
        #expect(sight(depthMM: 50, ratePerMin: 120).quality(against: adult) == .onTarget)

        #expect(sight(depthMM: 49.9).quality(against: adult) == .offTarget)
        #expect(sight(ratePerMin: 99.9).quality(against: adult) == .offTarget)
        #expect(sight(ratePerMin: 120.1).quality(against: adult) == .offTarget)

        #expect(sight(lock: .estimating).quality(against: adult) == .unseen)
        #expect(sight(sincePause: 2).quality(against: adult) == .unseen)
        #expect(sight(lock: .lost).quality(against: adult) == .unseen)
        // A rate that can be judged and is wrong counts against the look even when depth cannot be seen.
        #expect(sight(lock: .rateOnly, ratePerMin: 80).quality(against: adult) == .offTarget)
    }

    @Test("Deeper than the target maximum is not held against the look: too deep cannot be measured well enough")
    func noUpperLimitOnDepth() {
        #expect(sight(depthMM: 75).quality(against: .adult) == .onTarget)
    }
}
