import Foundation
import Testing
@testable import PlumbCapture

struct RestTopTrackerTests {
    func tracker() -> RestTopTracker {
        RestTopTracker(spanS: 1.5, steadyS: 0.1, minReadings: 10)
    }

    /// Feeds `heightM(t)` at 60 frames a second from `start` for `seconds`.
    func feed(_ tracker: inout RestTopTracker, from start: TimeInterval = 0, seconds: TimeInterval,
              _ heightM: (TimeInterval) -> Double) {
        for frame in 0..<Int((seconds * 60).rounded()) {
            let t = start + Double(frame) / 60
            tracker.add(heightM(t), at: t)
        }
    }

    @Test func noTopUntilEnoughSteadiedHeights() {
        var top = tracker()
        // Two readings are too few to steady; from the third each gives one steadied height, and
        // ten of those are needed.
        for frame in 0..<12 {
            #expect(top.topM == nil)
            top.add(0.3, at: Double(frame) / 60)
        }
        #expect(top.topM == 0.3)
    }

    @Test func theTopIsTheTopOfTheStroke() throws {
        // 110 strokes a minute, 50 mm deep, the hands' top at 0.325 m.
        var top = tracker()
        feed(&top, seconds: 4) { 0.3 + 0.025 * cos(2 * .pi * 110 / 60 * $0) }
        let topM = try #require(top.topM)
        // The steadying median trims the very peak by about a millimetre, never more than two.
        #expect(topM <= 0.325 && topM > 0.323)
    }

    @Test func oneWildFrameCannotLiftTheTop() {
        var top = tracker()
        feed(&top, seconds: 1) { t in abs(t - 0.5) < 0.001 ? 0.4 : 0.3 }
        #expect(top.topM == 0.3)
    }

    @Test func oldTopsAgeOut() throws {
        var top = tracker()
        feed(&top, seconds: 1) { _ in 0.32 }
        // The cushion settles 2 cm: within the span the old top holds, after it the new one.
        feed(&top, from: 1, seconds: 1) { _ in 0.30 }
        #expect(top.topM == 0.32)
        feed(&top, from: 2, seconds: 1) { _ in 0.30 }
        #expect(top.topM == 0.30)
    }

    @Test func withoutReadingsTheTopFades() {
        var top = tracker()
        feed(&top, seconds: 1) { _ in 0.3 }
        top.advance(to: 1.5)
        #expect(top.topM == 0.3)
        top.advance(to: 2.6)
        #expect(top.topM == nil)
    }

    @Test func aClockThatStepsBackStartsOver() {
        var top = tracker()
        feed(&top, from: 10, seconds: 1) { _ in 0.3 }
        top.add(0.1, at: 0)
        #expect(top.topM == nil)
    }
}
