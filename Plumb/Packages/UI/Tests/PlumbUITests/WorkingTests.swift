import CoreGraphics
import PlumbContracts
import Testing
@testable import PlumbUI

@MainActor
@Suite struct WorkingTimelineTests {
    @Test func theLogBecomesThreeRows() {
        let timeline = WorkingFixture.timeline
        #expect(timeline.strokes.count == Fixture.strokes(SyntheticSession.demo).count)
        #expect(timeline.pauses == [WorkingTimeline.Pause(start: 20.4, durationS: 25.7 - 20.4)])
        #expect(timeline.suggestions.map(\.name) == ["Read depth", "Find AED"])
        #expect(timeline.decisions.map(\.label) == ["Push harder", "Good", "Stop compressions", "Push now", "Good"])
        #expect(timeline.sampleRate == "60 a second")
        #expect(timeline.window == 0...37.5)
    }

    @Test func aToolCallsSpanEndsWhenItWasLogged() throws {
        let call = try #require(WorkingFixture.timeline.suggestions.last)
        #expect(abs(call.start - (29.6 - 2.1)) < 1e-9)
        #expect(call.durationS == 2.1)
        #expect(call.ok)
        #expect(call.sentence == "A model looked through the camera for an AED sign.")
    }

    @Test func whatTheRulesRefusedIsMarkedRefusedAndGivesItsReason() throws {
        let refusals = WorkingFixture.timeline.decisions.filter(\.refused)
        let refused = try #require(refusals.first)
        #expect(refused.label == "Stop compressions")
        #expect(refused.sentence.hasPrefix("A model may never tell the rescuer to stop"))
        #expect(refusals.count == 1)
    }

    @Test func aCueSaysWhenItWasSpokenAndThatARuleChoseIt() throws {
        let timeline = WorkingFixture.timeline
        let sentence = try #require(timeline.sentence(for: .decision(WorkingFixture.firstCueID)))
        #expect(sentence == "“Push harder” was spoken at 0:04, chosen by a fixed rule.")
        #expect(timeline.sentence(for: .decision(-1)) == nil)
        #expect(timeline.sentence(for: .suggestion(1001)) == "A model read the last ten depths to answer a spoken question.")
    }

    @Test func somethingAModelPointedAtIsADecisionOfTheSensors() {
        let log = [
            LogEntry(id: 1, t: 3, source: .rule,
                     body: .found(label: "AED cabinet", distanceM: 4.2, accepted: true, reason: "The sign was 4 m away and held still.")),
            LogEntry(id: 2, t: 6, source: .rule,
                     body: .found(label: "Fire extinguisher", distanceM: nil, accepted: false, reason: "It was red, not green.")),
            LogEntry(id: 3, t: 9, source: .system, body: .note("ignored")),
        ]
        let timeline = WorkingTimeline(log: log, sampleRate: "60 a second", cueWords: WorkingFixture.cueWords)
        #expect(timeline.decisions.map(\.refused) == [false, true])
        #expect(timeline.decisions.map(\.sentence) == ["The sign was 4 m away and held still.", "It was red, not green."])
        #expect(timeline.window == 3...9)
    }

    /// A tool's name in the log is an identifier. People are shown plain words, never the identifier.
    @Test func aToolsNameIsShownInPlainWords() {
        let log = [
            LogEntry(id: 1, t: 2, source: .model, body: .toolCall(name: "read_depth", durationS: 1, ok: true, summary: "")),
            LogEntry(id: 2, t: 4, source: .model, body: .toolCall(name: "find-aed", durationS: 1, ok: true, summary: "")),
            LogEntry(id: 3, t: 6, source: .model, body: .toolCall(name: "Ask the crew", durationS: 1, ok: true, summary: "")),
        ]
        let plain = WorkingTimeline(log: log, sampleRate: "", cueWords: WorkingFixture.cueWords)
        #expect(plain.suggestions.map(\.name) == ["Read depth", "Find aed", "Ask the crew"])
        #expect(plain.suggestions.allSatisfy { !$0.name.contains("_") && !$0.name.contains("-") })

        let chosen = WorkingTimeline(log: log, sampleRate: "", cueWords: WorkingFixture.cueWords,
                                     toolWords: { $0 == "find-aed" ? "Find AED" : "Other" })
        #expect(chosen.suggestions.map(\.name) == ["Other", "Find AED", "Other"])
    }

    // MARK: The window

    private var straddling: WorkingTimeline {
        let bar = StrokeBar(depthMM: 52, reached: true, trust: .locked)
        return WorkingTimeline(
            window: 10...20,
            strokes: [.init(t: 5, bar: bar), .init(t: 15, bar: bar), .init(t: 25, bar: bar)],
            pauses: [.init(start: 8, durationS: 4), .init(start: 30, durationS: 2)],
            sampleRate: "",
            suggestions: [.init(id: 1, start: 9, durationS: 2, name: "a", sentence: ""),
                          .init(id: 2, start: 21, durationS: 1, name: "b", sentence: ""),
                          .init(id: 3, start: 19.5, durationS: 3, name: "c", sentence: "")],
            decisions: [.init(id: 1, t: 9.9, label: "x", sentence: ""), .init(id: 2, t: 10, label: "y", sentence: ""),
                        .init(id: 3, t: 20, label: "z", sentence: ""), .init(id: 4, t: 20.1, label: "w", sentence: "")])
    }

    /// The app may narrow the window to the last stretch of a long session. What falls outside is not drawn.
    @Test func onlyWhatFallsInsideTheWindowIsShown() {
        let visible = straddling.visible
        #expect(visible.strokes.map(\.t) == [15])
        #expect(visible.pauses.map(\.start) == [8])
        #expect(visible.suggestions.map(\.id) == [1, 3])
        #expect(visible.decisions.map(\.id) == [2, 3])
        // A span keeps its true length, because that is the number its label states.
        #expect(visible.suggestions.map(\.durationS) == [2, 3])
        #expect(visible.window == 10...20)
    }

    @Test func whatStraddlesTheWindowIsCutAtItsEdge() {
        let timeline = straddling.visible
        let layout = WorkingRowsLayout(size: CGSize(width: 500, height: 240), window: timeline.window,
                                       targets: .adult, unit: 1)
        let track = layout.measured
        let pause = layout.pauseRect(timeline.pauses[0])
        #expect(pause.minX == track.minX)
        #expect(pause.maxX < layout.axis.x(12))
        for suggestion in timeline.suggestions {
            let span = layout.spanRect(suggestion)
            #expect(span.minX >= track.minX - 1e-9)
            #expect(span.maxX <= track.maxX + 1e-9)
            #expect(span.width >= Theme.metrics.markSize - 1e-9)
        }
    }

    @Test func anEmptyLogIsAnEmptyTimeline() {
        let timeline = WorkingTimeline(log: [], sampleRate: "", cueWords: WorkingFixture.cueWords)
        #expect(timeline.strokes.isEmpty && timeline.decisions.isEmpty && timeline.suggestions.isEmpty)
        #expect(timeline.window == 0...0)
    }
}

@Suite struct LabelFitTests {
    private func fit(_ marks: [ClosedRange<CGFloat>], widths: [CGFloat], order: [Int]? = nil, rows: Int = 3,
                     bounds: ClosedRange<CGFloat> = 0...400) -> [LabelFit.Placement?] {
        LabelFit.placements(marks: marks, labelWidths: widths, order: order ?? Array(marks.indices), rows: rows,
                            gap: 6, bounds: bounds)
    }

    @Test func aLabelSitsBesideItsMarkWhenThereIsRoom() {
        #expect(fit([10...18, 200...208], widths: [80, 80]) == [.init(x: 24, row: 0), .init(x: 214, row: 0)])
    }

    @Test func aLabelThatWouldRunIntoTheNextMarkDropsALine() {
        #expect(fit([10...18, 60...68], widths: [80, 40]) == [.init(x: 10, row: 1), .init(x: 74, row: 0)])
    }

    @Test func crowdedLabelsStaggerDownTheLines() {
        let placed = fit([10...18, 40...48, 70...78, 100...108], widths: [120, 120, 120, 120])
        #expect(placed[0] == .init(x: 10, row: 1))
        #expect(placed[1] == .init(x: 40, row: 2))
        #expect(placed[2] == nil)
        #expect(placed[3] == .init(x: 114, row: 0))
    }

    @Test func theMostImportantLabelIsPlacedFirst() {
        // Two long labels and one spare line: only one of them can be shown.
        let marks: [ClosedRange<CGFloat>] = [10...18, 40...48]
        #expect(fit(marks, widths: [300, 300], rows: 2, bounds: 0...330) == [.init(x: 10, row: 1), nil])
        #expect(fit(marks, widths: [300, 300], order: [1, 0], rows: 2, bounds: 0...330) == [nil, .init(x: 30, row: 1)])
    }

    @Test func aLabelNearTheRightEdgeIsPulledBackInside() {
        #expect(fit([380...388], widths: [90]) == [.init(x: 310, row: 1)])
    }

    @Test func aLabelWiderThanTheLaneIsLeftOut() {
        #expect(fit([10...18], widths: [500]) == [nil])
    }

    @Test func placedLabelsNeverOverlapEachOtherOrAMark() {
        let marks: [ClosedRange<CGFloat>] = [5...13, 30...38, 52...60, 120...128, 133...141, 300...308, 372...380]
        let widths: [CGFloat] = [70, 36, 130, 70, 36, 82, 60]
        let placed = fit(marks, widths: widths)
        var taken: [Int: [ClosedRange<CGFloat>]] = [0: marks]
        for (index, placement) in placed.enumerated() {
            guard let placement else { continue }
            let span = placement.x...(placement.x + widths[index])
            #expect(span.lowerBound >= 0 && span.upperBound <= 400)
            for other in taken[placement.row, default: []] {
                #expect(!span.overlaps(other), "label \(index) overlaps on row \(placement.row)")
            }
            taken[placement.row, default: []].append(span)
        }
        #expect(placed.compactMap { $0 }.count >= 5)
    }
}

@MainActor
@Suite struct WorkingRowsLayoutTests {
    static let size = CGSize(width: 500, height: 240)

    private var layout: WorkingRowsLayout {
        WorkingRowsLayout(size: Self.size, window: WorkingFixture.timeline.window, targets: .adult, unit: 1)
    }

    @Test func theThreeRowsStackWithoutOverlappingAndShareOneAxis() {
        let layout = layout
        #expect(layout.measured.maxY <= layout.suggested.minY)
        #expect(layout.suggested.maxY <= layout.decided.minY)
        #expect(layout.decided.maxY <= Self.size.height)
        #expect(layout.measured.minX == layout.suggested.minX)
        #expect(layout.suggested.minX == layout.decided.minX)
        #expect(layout.measured.minX == Theme.metrics.rowLabelWidth)
        #expect(layout.measured.height >= 60)
    }

    @Test func aMeasuredPushUsesTheSameScaleAsTheRescueScreen() throws {
        let layout = layout
        let stroke = WorkingTimeline.Stroke(t: 10, bar: StrokeBar(depthMM: 50, reached: true, trust: .locked))
        let rect = layout.strokeRect(stroke, tickLength: 20)
        #expect(rect.maxY == layout.scale.y(50))
        #expect(abs(rect.midX - layout.axis.x(10)) < 1e-9)
        #expect(abs(layout.scale.y(50) - layout.measured.height * 50 / 70) < 1e-9)
    }

    /// A logged pause starts at the last push before it and ends at the first after it,
    /// so its block is drawn between those two bars, clear of both, and through the line.
    @Test func aPauseSitsBetweenThePushesAtItsEdges() throws {
        let layout = layout
        let bar = StrokeBar(depthMM: 52, reached: true, trust: .locked)
        let before = layout.strokeRect(WorkingTimeline.Stroke(t: 20.4, bar: bar), tickLength: 20)
        let after = layout.strokeRect(WorkingTimeline.Stroke(t: 25.7, bar: bar), tickLength: 20)
        let pause = layout.pauseRect(WorkingTimeline.Pause(start: 20.4, durationS: 25.7 - 20.4))
        #expect(abs(pause.minX - (before.maxX + Theme.metrics.pauseMargin)) < 1e-9)
        #expect(abs(pause.maxX - (after.minX - Theme.metrics.pauseMargin)) < 1e-9)
        #expect(pause.minY == layout.measured.minY)
        #expect(pause.maxY == layout.measured.maxY)
    }

    @Test func aMarkLinesUpWithTheMomentItWasDecided() throws {
        let layout = layout
        let decision = try #require(WorkingFixture.timeline.decisions.first)
        #expect(abs(layout.markRect(decision).midX - layout.axis.x(decision.t)) < 1e-9)
        #expect(layout.decided.contains(layout.markRect(decision)))
    }

    @Test func aFastToolCallIsStillWideEnoughToPress() {
        let layout = layout
        let call = WorkingTimeline.Suggestion(id: 1, start: 5, durationS: 0.01, name: "x", sentence: "")
        #expect(layout.spanRect(call).width == Theme.metrics.markSize)
    }

    @Test func tappingAMarkOrItsLabelSelectsIt() throws {
        let layout = layout
        let timeline = WorkingFixture.timeline
        let first = try #require(timeline.decisions.first)
        let mark = layout.markRect(first)
        #expect(layout.selection(at: CGPoint(x: mark.midX, y: mark.midY), in: timeline) == .decision(first.id))
        // Just right of the mark is where its label is drawn.
        #expect(layout.selection(at: CGPoint(x: mark.maxX + 30, y: mark.midY), in: timeline) == .decision(first.id))
        // And on the lines below it.
        #expect(layout.selection(at: CGPoint(x: mark.midX + 4, y: layout.decided.maxY - 4), in: timeline) == .decision(first.id))
    }

    @Test func tappingASpanSelectsItsToolCall() throws {
        let layout = layout
        let timeline = WorkingFixture.timeline
        let call = try #require(timeline.suggestions.last)
        let span = layout.spanRect(call)
        #expect(layout.selection(at: CGPoint(x: span.midX, y: span.midY), in: timeline) == .suggestion(call.id))
    }

    /// The lanes are narrow, so a finger that lands in the gap beside one still gets its mark.
    @Test func aTapJustOutsideALaneStillBelongsToIt() throws {
        let layout = layout
        let timeline = WorkingFixture.timeline
        let call = try #require(timeline.suggestions.last)
        let span = layout.spanRect(call)
        let above = CGPoint(x: span.midX, y: layout.suggested.minY - 3)
        let below = CGPoint(x: span.midX, y: layout.suggested.maxY + 3)
        #expect(layout.selection(at: above, in: timeline) == .suggestion(call.id))
        #expect(layout.selection(at: below, in: timeline) == .suggestion(call.id))
        let first = try #require(timeline.decisions.first)
        let overMark = CGPoint(x: layout.markRect(first).midX, y: layout.decided.minY - 3)
        #expect(layout.selection(at: overMark, in: timeline) == .decision(first.id))
    }

    @Test func tappingTheBarsOrBeforeTheFirstMarkSelectsNothing() throws {
        let layout = layout
        let timeline = WorkingFixture.timeline
        #expect(layout.selection(at: CGPoint(x: layout.measured.midX, y: layout.measured.midY), in: timeline) == nil)
        let first = try #require(timeline.decisions.first)
        let before = CGPoint(x: layout.markRect(first).minX - Theme.metrics.hitSlop - 4, y: layout.decided.minY + 4)
        #expect(layout.selection(at: before, in: timeline) == nil)
    }

    @Test func theSelectionHairlineStopsAtTheSelectedMark() throws {
        let layout = layout
        let timeline = WorkingFixture.timeline
        let first = try #require(timeline.decisions.first)
        let cursor = try #require(layout.cursor(for: .decision(first.id), in: timeline))
        #expect(cursor.x == layout.markRect(first).midX)
        #expect(cursor.maxY == layout.markRect(first).maxY)
        #expect(layout.cursor(for: .decision(-1), in: timeline) == nil)
    }
}
