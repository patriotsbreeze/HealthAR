import Foundation
import PlumbContracts
import Testing
@testable import PlumbSignal

@Suite struct SpikeGateTests {
    private func gate() -> SpikeGate {
        SpikeGate(jumpMM: 30, maxSpeedMMPerS: 1500)
    }

    /// Feeds heights one sixtieth of a second apart and returns everything released, in order.
    private func feed(_ heights: [Double], step: Double = 1.0 / 60) -> [CleanReading] {
        var gate = gate()
        var out: [CleanReading] = []
        for (index, height) in heights.enumerated() {
            let (first, second) = gate.admit(t: Double(index) * step, heightMM: height)
            out += [first, second].compactMap { $0 }
        }
        return out
    }

    @Test func ordinaryReadingsPassStraightThrough() {
        var gate = gate()
        for (index, height) in [0.0, 5, 12, 20, 14, 3].enumerated() {
            let (first, second) = gate.admit(t: Double(index) / 60, heightMM: height)
            #expect(first == CleanReading(t: Double(index) / 60, heightMM: height))
            #expect(second == nil)
        }
    }

    @Test(arguments: [60.0, -60.0])
    func aOneSampleSpikeIsDropped(spike: Double) {
        let out = feed([0, 1, 2 + spike, 3, 4])
        #expect(out.map(\.heightMM) == [0, 1, 3, 4])
    }

    @Test func fastRealMotionPassesUnchanged() {
        // 40 mm between samples a thirtieth of a second apart is 1200 mm/s: quick, but a hand can do it.
        // Each big move is held for one sample and then released, so the last reading settles the one before.
        let heights = [0.0, -40, -80, -85, -50, -10, -5]
        #expect(feed(heights, step: 1.0 / 30).map(\.heightMM) == heights)
    }

    @Test func aLastingShiftIsCancelledOut() {
        let out = feed([0, 1, 2, 47, 48, 49, 50])
        #expect(out.map(\.heightMM) == [0, 1, 2, 2, 3, 4, 5])
    }

    @Test func aGlitchLastingTwoSamplesIsCancelledBothWays() {
        let out = feed([0, 0, 60, 60, 0, 0, 0])
        #expect(out.map(\.heightMM) == [0, 0, 0, 0, 0, 0, 0])
    }

    @Test func twoNoisySamplesInARowAreNotMistakenForAShift() {
        // A low reading, then a high one, then back to normal: the next reading is not far from the low one.
        let out = feed([0, -16, 15, 2, 0, 1])
        #expect(out.map(\.heightMM) == [0, -16, 15, 2, 0, 1])
    }
}

@Suite struct TroughFitTests {
    private func window(_ points: [(t: Double, h: Double)]) -> SampleWindow {
        var window = SampleWindow(capacity: 64, spanS: 10)
        for point in points {
            window.append(TracePoint(t: point.t, rawMM: point.h, smoothMM: point.h))
        }
        return window
    }

    @Test func itFindsATurnThatFallsBetweenSamples() throws {
        // A parabola bottoming out at t = 1.007, height -42, sampled every 1/60 s.
        let points = (0..<20).map { index -> (t: Double, h: Double) in
            let t = 0.85 + Double(index) / 60
            return (t, -42 + 4000 * (t - 1.007) * (t - 1.007))
        }
        let bottom = try #require(TroughFit.measure(in: window(points), since: 0.85, halfWindowS: 0.07))
        #expect(abs(bottom.heightMM + 42) < 1e-6)
        #expect(abs(bottom.t - 1.007) < 1e-6)
        #expect(bottom.surroundMM > bottom.heightMM)
    }

    @Test func aFlatBottomReadsAsItsAverage() throws {
        let points = (0..<12).map { index -> (t: Double, h: Double) in
            let wobble = index % 2 == 0 ? 0.5 : -0.5
            return (Double(index) / 60, -30 + wobble)
        }
        let bottom = try #require(TroughFit.measure(in: window(points), since: 0, halfWindowS: 1))
        #expect(abs(bottom.heightMM + 30) < 0.2)
    }

    @Test func aTurnNotYetReachedIsNotGuessedAt() throws {
        // Still going down: the curve's turning point lies beyond the last reading.
        let points = (0..<8).map { index -> (t: Double, h: Double) in
            let t = Double(index) / 60
            return (t, 2000 * (t - 0.5) * (t - 0.5) - 500)
        }
        let bottom = try #require(TroughFit.measure(in: window(points), since: 0, halfWindowS: 0.07))
        let lastHeight = try #require(points.last).h
        #expect(abs(bottom.heightMM - lastHeight) < 1e-6)
        #expect(abs(bottom.t - 7.0 / 60) < 1e-9)
    }

    @Test func tooFewReadingsFallBackToTheLowestOne() throws {
        let bottom = try #require(TroughFit.measure(in: window([(0, -10), (0.02, -20)]), since: 0, halfWindowS: 0.07))
        #expect(bottom.heightMM == -20)
        #expect(bottom.t == 0.02)
        #expect(TroughFit.measure(in: window([]), since: 0, halfWindowS: 0.07) == nil)
    }

    @Test func readingsBeforeTheStrokeBeganAreNotItsBottom() throws {
        let points: [(t: Double, h: Double)] = [(0, -90), (0.1, 0), (0.2, -20), (0.3, -30), (0.4, -20)]
        let bottom = try #require(TroughFit.measure(in: window(points), since: 0.15, halfWindowS: 0.15))
        #expect(abs(bottom.t - 0.3) < 1e-9)
        #expect(abs(bottom.heightMM + 30) < 1e-9)
    }
}

@Suite struct TopDwellTests {
    /// A rise, a flat rest at `level`, then a drop, with the smoothed height equal to the raw height.
    private func restThenDrop(level: Double, stray: Double = 0) -> SampleWindow {
        var window = SampleWindow(capacity: 64, spanS: 10)
        for index in 0..<30 {
            let t = Double(index) / 60
            var height = level
            if index < 5 { height = level - Double(5 - index) * 8 }
            if index > 22 { height = level - Double(index - 22) * 8 }
            if index == 12 { height += stray }
            window.append(TracePoint(t: t, rawMM: height, smoothMM: height))
        }
        return window
    }

    @Test func theTopIsTheAverageOverTheRest() throws {
        let top = try #require(TopDwell.measure(in: restThenDrop(level: 7), after: -1, bandMM: 4, lagS: 0))
        #expect(abs(top.heightMM - 7) < 1e-9)
        #expect(abs(top.leftAt - 22.0 / 60) < 1e-9)
    }

    @Test func oneStrayHighReadingDoesNotBecomeTheTop() throws {
        let top = try #require(TopDwell.measure(in: restThenDrop(level: 7, stray: 20), after: -1, bandMM: 4, lagS: 0))
        #expect(top.heightMM < 9, "the stray reading is one of eighteen in the rest, not the whole of it")
    }

    @Test func readingsFromBeforeTheStartAreLeftOut() throws {
        var window = restThenDrop(level: 7)
        window.append(TracePoint(t: 0.6, rawMM: -40, smoothMM: -40))
        window.append(TracePoint(t: 0.62, rawMM: -41, smoothMM: -41))
        let top = try #require(TopDwell.measure(in: window, after: 0.55, bandMM: 4, lagS: 0))
        #expect(abs(top.heightMM + 40.5) < 1e-9)
        #expect(TopDwell.measure(in: window, after: 5, bandMM: 4, lagS: 0) == nil)
    }

    @Test func theDwellIsShiftedBackByTheSmoothingLag() throws {
        // Smoothed height trails the raw height by two samples; the raw drop begins two samples earlier.
        var window = SampleWindow(capacity: 64, spanS: 10)
        let raw = [0.0, 0, 0, 0, 0, 0, -10, -20, -30, -40]
        for index in raw.indices {
            window.append(TracePoint(t: Double(index) / 60, rawMM: raw[index], smoothMM: index >= 2 ? raw[index - 2] : 0))
        }
        let top = try #require(TopDwell.measure(in: window, after: -1, bandMM: 4, lagS: 2.0 / 60))
        #expect(abs(top.heightMM) < 1e-9)
        #expect(abs(top.leftAt - 5.0 / 60) < 1e-9)
    }
}

@Suite struct SmallPartsTests {
    @Test func theMeterTurnsOnWhenFullAndOffWhenEmpty() {
        var meter = EvidenceMeter()
        for _ in 0..<9 { meter.feed(true, for: 0.1, fillS: 1, drainS: 0.3) }
        #expect(!meter.isOn)
        for _ in 0..<2 { meter.feed(true, for: 0.1, fillS: 1, drainS: 0.3) }
        #expect(meter.isOn)

        meter.feed(false, for: 0.1, fillS: 1, drainS: 0.3)
        meter.feed(false, for: 0.1, fillS: 1, drainS: 0.3)
        #expect(meter.isOn, "a short contradiction does not turn it off")
        meter.feed(true, for: 1, fillS: 1, drainS: 0.3)
        for _ in 0..<4 { meter.feed(false, for: 0.1, fillS: 1, drainS: 0.3) }
        #expect(!meter.isOn)
    }

    @Test func thePauseLedgerDoesTheArithmetic() {
        var ledger = PauseLedger(pauseAfterS: 2)
        #expect(ledger.handsOnFraction(now: 5) == nil)
        let beganBeforeAnyStroke = ledger.beginPauseIfDue(now: 5)
        #expect(!beganBeforeAnyStroke)

        let first = ledger.recordStroke(at: 10)
        let second = ledger.recordStroke(at: 10.5)
        #expect(first == nil && second == nil)
        let beganTooSoon = ledger.beginPauseIfDue(now: 12.5)
        let beganWhenDue = ledger.beginPauseIfDue(now: 12.6)
        let beganTwice = ledger.beginPauseIfDue(now: 13)
        #expect(!beganTooSoon)
        #expect(beganWhenDue)
        #expect(!beganTwice, "a pause begins once")
        #expect(ledger.isPaused)
        #expect(abs(ledger.currentPauseS(now: 14.5) - 4) < 1e-9)
        #expect(abs((ledger.handsOnFraction(now: 14.5) ?? 0) - (1 - 4 / 4.5)) < 1e-9)

        let ended = ledger.recordStroke(at: 16.5)
        #expect(ended == 6)
        #expect(!ledger.isPaused)
        #expect(ledger.currentPauseS(now: 17) == 0)
        #expect(abs((ledger.handsOnFraction(now: 20) ?? 0) - 0.4) < 1e-9)
    }

    @Test func medianAndSpreadShrugOffOneWildValue() {
        #expect(RobustStats.median([]) == nil)
        #expect(RobustStats.median([4]) == 4)
        #expect(RobustStats.median([3, 1, 2]) == 2)
        #expect(RobustStats.median([4, 1, 3, 2]) == 2.5)
        #expect(RobustStats.median([50, 51, 49, 50, 190]) == 50)

        #expect(RobustStats.spread([50]) == nil)
        #expect(RobustStats.spread([50, 50, 50, 50, 50]) == 0)
        let calm = RobustStats.spread([49, 50, 50, 51, 190]) ?? 99
        #expect(calm < 1)
        let twoCamps = RobustStats.spread([35, 60, 35, 60, 35]) ?? 0
        #expect(twoCamps > 15)
    }

    @Test func theWindowKeepsOnlyRecentReadingsInOrder() {
        var window = SampleWindow(capacity: 4, spanS: 1)
        for index in 0..<10 {
            window.append(TracePoint(t: Double(index) * 0.1, rawMM: Double(index), smoothMM: 0))
        }
        #expect(window.count == 4)
        #expect((0..<4).map { window[$0].rawMM } == [6, 7, 8, 9])

        window.append(TracePoint(t: 5, rawMM: 50, smoothMM: 0))
        #expect(window.count == 1, "readings older than the span are let go")
        #expect(window[0].rawMM == 50)

        window.removeAll()
        #expect(window.count == 0)
    }

    @Test func smoothingDependsOnTimeNotOnHowManySamplesArrive() {
        // A step from 0 to 100: after one time constant the output is 63 % of the way, whatever the spacing.
        for step in [0.001, 0.005, 0.03] {
            var smoother = HeightSmoother(timeConstantS: 0.03)
            _ = smoother.smooth(CleanReading(t: 0, heightMM: 0))
            var t = 0.0
            var value = 0.0
            while t < 0.03 - 1e-9 {
                t += step
                value = smoother.smooth(CleanReading(t: t, heightMM: 100))
            }
            #expect(abs(value - 100 * (1 - exp(-1.0))) < 0.5, "spacing \(step)")
        }
    }
}
