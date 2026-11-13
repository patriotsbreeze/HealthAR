import PlumbContracts
import Testing
@testable import PlumbUI

@Suite struct BarLayoutTests {
    static let slots = 18
    static let reached = StrokeBar(depthMM: 54, reached: true, trust: .locked)
    static let short = StrokeBar(depthMM: 38, reached: false, trust: .locked)

    private func frame(_ marks: [BarFieldModel.Mark], since: Double? = 10, pause: Double = 0,
                       trust: LockState = .locked) -> BarFieldFrame {
        BarFieldFrame(marks: marks, liveDepthMM: 20, trust: trust, pauseSeconds: pause, sinceLastStroke: since)
    }

    private func layout(_ frame: BarFieldFrame, reduceMotion: Bool = false) -> BarFieldLayout {
        BarFieldLayout(frame: frame, slots: Self.slots, reduceMotion: reduceMotion)
    }

    private func strokes(_ count: Int, _ bar: StrokeBar = short) -> [BarFieldModel.Mark] {
        (0..<count).map { .stroke(StrokeBar(depthMM: Double($0), reached: bar.reached, trust: bar.trust)) }
    }

    // MARK: Stepping

    @Test func anEmptyFieldHasOnlyTheLiveBar() {
        let empty = layout(frame([], since: nil))
        #expect(empty.strokes.isEmpty)
        #expect(empty.blocks.isEmpty)
        #expect(empty.showsLiveBar)
        #expect(empty.linePulse == 0)
    }

    @Test func theNewestPushSitsNextToTheLiveBarAndOlderOnesStepLeft() {
        let placed = layout(frame(strokes(5)))
        #expect(placed.strokes.map(\.slot) == [1, 2, 3, 4, 5])
        // Depth doubles as an index here: the newest (4) is first.
        #expect(placed.strokes.map(\.bar.depthMM) == [4, 3, 2, 1, 0])
    }

    @Test func eachNewPushMovesEveryOlderOneExactlyOneSlot() {
        let before = layout(frame(strokes(6)))
        let after = layout(frame(strokes(7)))
        for stroke in before.strokes {
            let moved = after.strokes.first { $0.bar == stroke.bar }
            #expect(moved?.slot == stroke.slot + 1)
        }
    }

    @Test func onlySeventeenFinishedPushesFitBesideTheLiveBar() {
        let placed = layout(frame(strokes(30)))
        #expect(placed.strokes.count == Self.slots - 1)
        #expect(placed.strokes.first?.bar.depthMM == 29)
        #expect(placed.strokes.last?.slot == 17)
    }

    @Test func aNewPushSlidesOutFromUnderTheLiveBar() {
        let step = Theme.metrics.stepSeconds
        #expect(layout(frame(strokes(3), since: 0)).strokes.map(\.slot) == [0, 1, 2])
        let midway = layout(frame(strokes(3), since: step / 2)).strokes[0].slot
        #expect(midway > 0.5 && midway < 1)
        #expect(layout(frame(strokes(3), since: step)).strokes.map(\.slot) == [1, 2, 3])
    }

    @Test func aBarIsShownWholeOrNotAtAll() {
        for since in [0.0, 0.03, 0.06, 0.2] {
            for stroke in layout(frame(strokes(30), since: since)).strokes {
                #expect(stroke.slot >= 0)
                #expect(stroke.slot + 1 <= Double(Self.slots))
            }
        }
    }

    @Test func reduceMotionCutsTheStep() {
        let placed = layout(frame(strokes(3), since: 0), reduceMotion: true)
        #expect(placed.strokes.map(\.slot) == [1, 2, 3])
    }

    // MARK: Reaching the line

    @Test func reachingTheLineIsEmphasisedBriefly() {
        let marks = strokes(3) + [.stroke(Self.reached)]
        let arrived = layout(frame(marks, since: 0))
        #expect(arrived.linePulse == 1)
        #expect(arrived.strokes[0].swell == 1)
        #expect(arrived.strokes.dropFirst().allSatisfy { $0.swell == 0 })

        let fading = layout(frame(marks, since: Theme.metrics.emphasisSeconds / 2))
        #expect(fading.linePulse > 0 && fading.linePulse < 1)

        let settled = layout(frame(marks, since: Theme.metrics.emphasisSeconds))
        #expect(settled.linePulse == 0)
        #expect(settled.strokes[0].swell == 0)
    }

    @Test func fallingShortIsNeverEmphasised() {
        let placed = layout(frame(strokes(3) + [.stroke(Self.short)], since: 0))
        #expect(placed.linePulse == 0)
        #expect(placed.strokes.allSatisfy { $0.swell == 0 })
    }

    @Test func anUntrustedPushIsNeverEmphasisedEvenIfMarkedReached() {
        let estimate = StrokeBar(depthMM: 55, reached: true, trust: .estimating)
        let placed = layout(frame([.stroke(estimate)], since: 0))
        #expect(placed.linePulse == 0)
        #expect(placed.strokes[0].swell == 0)
    }

    @Test func reduceMotionHoldsTheEmphasisInsteadOfPulsing() {
        let marks = strokes(3) + [.stroke(Self.reached)]
        let placed = layout(frame(marks, since: 3), reduceMotion: true)
        #expect(placed.linePulse == 0)
        #expect(placed.strokes[0].swell == 1)
        #expect(placed.strokes[1].swell == 0)
    }

    // MARK: Trust

    @Test(arguments: [(LockState.locked, true), (.estimating, true), (.rateOnly, false), (.lost, false)])
    func theLiveBarIsDrawnOnlyWhenDepthMeansSomething(trust: LockState, shown: Bool) {
        #expect(layout(frame(strokes(2), trust: trust)).showsLiveBar == shown)
    }

    // MARK: Pauses

    @Test func aPauseGrowsFromTheRightOneSlotForEachMissedBeat() throws {
        let placed = layout(frame(strokes(20), pause: 4))
        let block = try #require(placed.blocks.first)
        let expected = 4 * Targets.adult.beatPerMin / 60
        #expect(block.isCurrent)
        #expect(block.fromSlot == 0)
        #expect(abs(block.toSlot - expected) < 1e-9)
        #expect(block.seconds == 4)
        #expect(!placed.showsLiveBar)
        #expect(abs((placed.strokes.first?.slot ?? 0) - expected) < 1e-9)
    }

    @Test func aLongerPauseIsAWiderBlock() throws {
        let four = try #require(layout(frame([], pause: 4)).blocks.first)
        let six = try #require(layout(frame([], pause: 6)).blocks.first)
        #expect(six.toSlot > four.toSlot)
    }

    @Test func aPauseNeverGrowsPastTheField() throws {
        let placed = layout(frame(strokes(20), pause: 30))
        let block = try #require(placed.blocks.first)
        #expect(block.toSlot == Double(Self.slots))
        #expect(placed.strokes.isEmpty)
    }

    @Test func aFinishedPauseStaysInTheHistoryAndStepsWithTheBars() throws {
        let marks: [BarFieldModel.Mark] = [.stroke(Self.short), .pause(seconds: 3), .stroke(Self.reached)]
        let placed = layout(frame(marks))
        let width = 3 * Targets.adult.beatPerMin / 60
        let block = try #require(placed.blocks.first)
        #expect(!block.isCurrent)
        #expect(block.fromSlot == 2)
        #expect(abs(block.toSlot - (2 + width)) < 1e-9)
        #expect(placed.strokes.map(\.bar) == [Self.reached, Self.short])
        #expect(abs(placed.strokes[1].slot - (2 + width)) < 1e-9)
        #expect(placed.showsLiveBar)
    }

    @Test func anOldPauseIsCutAtTheFieldsEdge() throws {
        let marks: [BarFieldModel.Mark] = [.pause(seconds: 60)] + strokes(4)
        let block = try #require(layout(frame(marks)).blocks.first)
        #expect(block.fromSlot == 5)
        #expect(block.toSlot == Double(Self.slots))
    }
}
