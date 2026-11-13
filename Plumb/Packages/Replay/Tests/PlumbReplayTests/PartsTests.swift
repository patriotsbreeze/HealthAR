import Foundation
import PlumbContracts
import PlumbGeometry
import Testing
@testable import PlumbReplay

/// The small pieces the replay is built from.
@Suite struct PartsTests {
    private func frame(pitchPx: Double?) -> TraceFrame {
        var frame = Rig().frames(following: [HeightSample(t: 0, heightMM: 0)])[0]
        frame.handsLuma = pitchPx.map { LumaPatch(width: 1, height: 2, pitchPx: $0, pixels: [0, 0]) }
        return frame
    }

    @Test func aNewGridSpacingMarksANewPlacement() {
        var watch = ReseedWatch()
        // A frame without a grid says nothing, and is not taken for a change.
        let seen = [2.5, 2.5, nil, 2.5, 2.6, 2.6].map { watch.isNewPlacement(frame(pitchPx: $0)) }
        #expect(seen == [false, false, false, false, true, false])
    }

    @Test func timeLockedIsAddedUpFromTheChanges() {
        var clock = LockClock()
        clock.start(at: 1)
        clock.change(to: .rateOnly, at: 1)
        clock.change(to: .locked, at: 2)
        clock.change(to: .estimating, at: 5)
        clock.change(to: .locked, at: 6)
        #expect(clock.lockedSeconds(until: 10) == 3 + 4)
        // Asking does not move the clock on.
        #expect(clock.lockedSeconds(until: 8) == 3 + 2)
    }

    @Test func ticksFallOnAnEvenBeatFromTheFirstFrame() {
        var ticks = TickClock(ticksPerSecond: 10)
        #expect(ticks.due(before: 1.0) == [])
        #expect(ticks.due(before: 1.05) == [1.0])
        #expect(ticks.due(before: 1.32).count == 3)
        #expect(ticks.due(before: 1.32) == [])
        var never = TickClock(ticksPerSecond: 0)
        #expect(never.due(before: 5) == [])
    }

    @Test func quantilesInterpolateBetweenNeighbours() {
        #expect(Stats.median([3, 1, 2]) == 2)
        #expect(Stats.median([4, 1, 2, 3]) == 2.5)
        #expect(Stats.quantile([10, 20], 0.25) == 12.5)
        #expect(Stats.median([]) == nil)
        #expect(Stats.interquartileRange([7]) == 0)
    }

    @Test func aFingerprintFollowsTheBytes() throws {
        let one = TraceFingerprint(of: Data("one".utf8))
        #expect(one == TraceFingerprint(of: Data("one".utf8)))
        #expect(one != TraceFingerprint(of: Data("two".utf8)))
        #expect(one.value.count == 16)
        let hex = one.value.allSatisfy(\.isHexDigit)
        #expect(hex)
    }
}
