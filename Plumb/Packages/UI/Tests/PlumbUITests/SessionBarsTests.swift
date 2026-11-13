import CoreGraphics
import PlumbContracts
import Testing
@testable import PlumbUI

@Suite struct SessionBarsTests {
    static let size = CGSize(width: 834, height: 120)

    private func stats(buckets: [HandoffStats.Bucket] = [], pauses: [HandoffStats.Pause] = [],
                       durationS: Double = 100) -> HandoffStats {
        HandoffStats(durationS: durationS, pauses: pauses, buckets: buckets)
    }

    private func bucket(start: Double, compressions: Int = 18, depthMM: Double?) -> HandoffStats.Bucket {
        HandoffStats.Bucket(start: start, lengthS: 10, compressions: compressions, depthMM: depthMM, pausedS: 0)
    }

    @Test func aSliceThatReachedTheLineEndsOnOrBelowIt() throws {
        let layout = SessionBarsLayout(size: Self.size, stats: stats(), unit: 1)
        let onTheLine = try #require(layout.column(bucket(start: 0, depthMM: 50), targets: .adult))
        #expect(onTheLine.style == .reached)
        #expect(onTheLine.rect.maxY == layout.scale.y(50))
        let short = try #require(layout.column(bucket(start: 10, depthMM: 41), targets: .adult))
        #expect(short.style == .short)
        #expect(short.rect.maxY < layout.scale.y(50))
    }

    @Test func aSliceWithPushesButNoTrustedDepthIsATick() throws {
        let layout = SessionBarsLayout(size: Self.size, stats: stats(), unit: 1)
        let column = try #require(layout.column(bucket(start: 0, depthMM: nil), targets: .adult))
        #expect(column.style == .tick)
        #expect(column.rect.height == Theme.metrics.tickLength)
    }

    @Test func aSliceWithNoPushesDrawsNothing() {
        let layout = SessionBarsLayout(size: Self.size, stats: stats(), unit: 1)
        #expect(layout.column(bucket(start: 0, compressions: 0, depthMM: nil), targets: .adult) == nil)
    }

    @Test func slicesSitAtTheirPlaceInTime() throws {
        let layout = SessionBarsLayout(size: Self.size, stats: stats(durationS: 100), unit: 1)
        let first = try #require(layout.column(bucket(start: 0, depthMM: 52), targets: .adult))
        let last = try #require(layout.column(bucket(start: 90, depthMM: 52), targets: .adult))
        let slot = layout.plot.width / 10
        #expect(abs(first.rect.midX - (layout.plot.minX + slot / 2)) < 1e-9)
        #expect(abs(last.rect.midX - (layout.plot.maxX - slot / 2)) < 1e-9)
        #expect(abs(first.rect.width - slot * Theme.metrics.barFill) < 1e-9)
    }

    @Test func aPauseIsAsWideAsItWasLongAndStandsTallerThanAnyBar() throws {
        let layout = SessionBarsLayout(size: Self.size, stats: stats(durationS: 100), unit: 1)
        let rect = layout.pauseRect(HandoffStats.Pause(start: 40, durationS: 10))
        #expect(abs(rect.minX - layout.axis.x(40)) < 1e-9)
        #expect(abs(rect.width - layout.plot.width / 10) < 1e-9)
        #expect(rect.minY == layout.plot.minY)
        #expect(rect.maxY == layout.plot.maxY)
        // Even the deepest push the scale can show stops above where a pause's time label begins.
        let deepest = try #require(layout.column(bucket(start: 0, depthMM: 60), targets: .adult))
        #expect(deepest.rect.maxY < rect.maxY)
    }

    @Test func aBriefPauseIsNeverTooThinToSee() {
        let layout = SessionBarsLayout(size: Self.size, stats: stats(durationS: 3_600), unit: 1)
        let rect = layout.pauseRect(HandoffStats.Pause(start: 3_599.5, durationS: 0.2))
        #expect(rect.width == Theme.metrics.minimumPauseWidth)
        #expect(rect.maxX <= layout.plot.maxX + 1e-9)
    }

    // MARK: Bars beside a pause

    /// A ten-second slice starting at 40 s: its bar covers the middle 62% of 40...50 s.
    private func barBeside(pauseFrom start: Double, lasting durationS: Double) throws
        -> (whole: CGRect, standing: [SessionBarsLayout.Column], pause: CGRect) {
        let layout = SessionBarsLayout(size: Self.size, stats: stats(durationS: 100), unit: 1)
        let column = try #require(layout.column(bucket(start: 40, depthMM: 52), targets: .adult))
        let pause = layout.pauseRect(HandoffStats.Pause(start: start, durationS: durationS))
        return (column.rect, layout.standing(column, clearOf: [pause]), pause)
    }

    @Test func aBarAwayFromEveryPauseIsLeftWhole() throws {
        let (whole, standing, _) = try barBeside(pauseFrom: 70, lasting: 5)
        #expect(standing.map(\.rect) == [whole])
    }

    @Test func aBarBesideAPauseIsCutBackToStandClearOfIt() throws {
        // The pause covers the last quarter of the bar.
        let (whole, standing, pause) = try barBeside(pauseFrom: 46.5, lasting: 6)
        let part = try #require(standing.first)
        #expect(standing.count == 1)
        #expect(part.rect.minX == whole.minX)
        #expect(abs(part.rect.maxX - (pause.minX - Theme.metrics.pauseMargin)) < 1e-9)
        #expect(part.rect.height == whole.height)
        #expect(part.style == .reached)
    }

    /// What is left of a bar must still read as a bar. A sliver beside a pause looks like a fault in the drawing.
    @Test func aSliverLeftByAPauseIsNotDrawn() throws {
        // The pause covers all but the first tenth of the bar.
        let (whole, standing, _) = try barBeside(pauseFrom: 42.6, lasting: 9)
        #expect(whole.width > 0)
        #expect(standing.isEmpty)
    }

    @Test func aPauseInsideABarLeavesTheSidesThatAreWideEnough() throws {
        let layout = SessionBarsLayout(size: Self.size, stats: stats(durationS: 20), unit: 1)
        let column = try #require(layout.column(bucket(start: 0, depthMM: 41), targets: .adult))
        let pause = layout.pauseRect(HandoffStats.Pause(start: 4.9, durationS: 0.2))
        let standing = layout.standing(column, clearOf: [pause])
        #expect(standing.count == 2)
        #expect(standing.allSatisfy { $0.style == .short })
        #expect(standing[0].rect.maxX < pause.minX && standing[1].rect.minX > pause.maxX)
    }

    @Test func theRecordCoversItsSlicesEvenWhenTheStatedDurationIsShort() {
        let buckets = [bucket(start: 0, depthMM: 50), bucket(start: 10, depthMM: 50)]
        let layout = SessionBarsLayout(size: Self.size, stats: stats(buckets: buckets, durationS: 12), unit: 1)
        #expect(layout.durationS == 20)
    }

    @Test func anEmptyRecordStillLaysOut() {
        let layout = SessionBarsLayout(size: Self.size, stats: HandoffStats(), unit: 1)
        #expect(layout.durationS == 0)
        #expect(layout.axis.x(0).isFinite)
    }
}
