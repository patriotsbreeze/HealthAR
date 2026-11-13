import Foundation
import PlumbContracts
import Testing
@testable import PlumbSession

@Suite struct WorldDigestBuilderTests {
    private func metrics(t: TimeInterval = 10, lock: LockState = .locked) -> Metrics {
        Metrics(t: t, lock: lock, count: 42, ratePerMin: 108, depthMM: 53, depthSpreadMM: 4,
                secondsSinceLastCompression: 0.4, isPaused: true, pauseSeconds: 3.5, handsOnFraction: 0.9,
                firstCompressionAt: 2)
    }

    @Test func freshLockedNumbersPassStraightThrough() {
        let digest = WorldDigestBuilder.make(metrics: metrics(), now: 10.5)
        #expect(digest == WorldDigest(lock: .locked, count: 42, ratePerMin: 108, depthMM: 53, depthSpreadMM: 4,
                                      isPaused: true, pauseSeconds: 3.5, handsOnFraction: 0.9, ageS: 0.5,
                                      stale: false))
    }

    @Test func numbersGoStaleWithAge() {
        #expect(WorldDigestBuilder.make(metrics: metrics(), now: 12).stale == false)
        let old = WorldDigestBuilder.make(metrics: metrics(), now: 12.5)
        #expect(old.ageS == 2.5)
        #expect(old.stale)
        // Old numbers are still handed over, marked stale, so a model can say how old they are.
        #expect(old.depthMM == 53)
    }

    @Test func theAgeLimitCanBeChosen() {
        #expect(WorldDigestBuilder.make(metrics: metrics(), now: 10.5, staleAfterS: 0.25).stale)
        #expect(WorldDigestBuilder.make(metrics: metrics(), now: 19, staleAfterS: 10).stale == false)
    }

    @Test func aLostLockIsStaleHoweverFresh() {
        let digest = WorldDigestBuilder.make(metrics: metrics(lock: .lost), now: 10)
        #expect(digest.ageS == 0)
        #expect(digest.stale)
    }

    @Test(arguments: LockState.allCases)
    func depthIsHiddenUnlessLocked(lock: LockState) {
        let digest = WorldDigestBuilder.make(metrics: metrics(lock: lock), now: 10)
        if lock == .locked {
            #expect(digest.depthMM == 53)
            #expect(digest.depthSpreadMM == 4)
        } else {
            #expect(digest.depthMM == nil)
            #expect(digest.depthSpreadMM == nil)
        }
        // Rhythm and count do not depend on depth being trusted.
        #expect(digest.ratePerMin == 108)
        #expect(digest.count == 42)
        #expect(digest.lock == lock)
        #expect(digest.stale == (lock == .lost))
    }

    @Test func aClockThatRunsBackwardsGivesAgeZeroNotANegativeAge() {
        #expect(WorldDigestBuilder.make(metrics: metrics(t: 10), now: 9).ageS == 0)
    }

    @Test func anAgeThatCannotBeWorkedOutIsStaleAndStillEncodes() throws {
        let digest = WorldDigestBuilder.make(metrics: metrics(t: .nan), now: 10)
        #expect(digest.stale)
        #expect(digest.ageS.isFinite)
        _ = try JSONEncoder().encode(digest)

        #expect(WorldDigestBuilder.make(metrics: metrics(), now: 10, staleAfterS: .nan).stale)
    }
}
