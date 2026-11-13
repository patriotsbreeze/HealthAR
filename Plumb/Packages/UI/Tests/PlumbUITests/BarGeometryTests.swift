import CoreGraphics
import PlumbContracts
import Testing
@testable import PlumbUI

@Suite struct BarGeometryTests {
    /// The field as it comes out on the phone, and on the mirrored display.
    static let cases: [(size: CGSize, unit: CGFloat)] = [
        (CGSize(width: 298, height: 169), 1),
        (CGSize(width: 436, height: 381), 1280.0 / 874.0),
    ]

    @Test(arguments: cases.indices)
    func aFiftyMillimetreStrokeEndsExactlyOnTheLine(index: Int) {
        let (size, unit) = Self.cases[index]
        let geometry = BarFieldGeometry(size: size, unit: unit)
        let lineY = geometry.scale.y(Targets.adult.depthMinMM)
        for slot in [0.0, 1, 9, 17] {
            #expect(geometry.barRect(slot: slot, depthMM: 50).maxY == lineY)
        }
        #expect(abs(lineY - size.height * 50 / 70) < 1e-9)
    }

    @Test func theScaleIsFixedAtSeventyMillimetres() {
        let geometry = BarFieldGeometry(size: CGSize(width: 298, height: 140), unit: 1)
        #expect(geometry.scale.y(0) == 0)
        #expect(geometry.scale.y(35) == 70)
        #expect(geometry.scale.y(70) == 140)
        #expect(geometry.barRect(slot: 1, depthMM: 0).height == 0)
    }

    @Test func deeperThanFullScaleStopsAtTheBottomEdge() {
        let geometry = BarFieldGeometry(size: CGSize(width: 298, height: 140), unit: 1)
        #expect(geometry.barRect(slot: 1, depthMM: 95).maxY == 140)
        #expect(geometry.scale.y(-4) == 0)
    }

    @Test func aShortStrokeStopsShortOfTheLineByItsShortfall() {
        let geometry = BarFieldGeometry(size: CGSize(width: 298, height: 140), unit: 1)
        let gap = geometry.scale.y(50) - geometry.barRect(slot: 2, depthMM: 38).maxY
        #expect(abs(gap - 12 * 2) < 1e-9)
    }

    @Test func slotsCountLeftwardsFromTheRightEdge() {
        let geometry = BarFieldGeometry(size: CGSize(width: 298, height: 169), unit: 1)
        let live = geometry.barRect(slot: 0, depthMM: 30)
        let newest = geometry.barRect(slot: 1, depthMM: 30)
        let oldest = geometry.barRect(slot: 17, depthMM: 30)
        #expect(geometry.slots == 18)
        #expect(live.maxX <= geometry.plot.maxX)
        #expect(abs(live.midX - (geometry.plot.maxX - geometry.slotWidth / 2)) < 1e-9)
        #expect(abs((live.minX - newest.minX) - geometry.slotWidth) < 1e-9)
        #expect(oldest.minX >= geometry.plot.minX)
        #expect(abs(live.width - geometry.slotWidth * Theme.metrics.barFill) < 1e-9)
    }

    @Test func barsNeverEnterTheLabelGutter() {
        let geometry = BarFieldGeometry(size: CGSize(width: 298, height: 169), unit: 1)
        #expect(geometry.plot.minX == Theme.metrics.fieldGutter)
        #expect(geometry.barRect(slot: 17, depthMM: 50, swell: 1).minX >= geometry.plot.minX - 1e-9)
    }

    @Test func emphasisWidensABarToFillItsSlotWithoutMovingIt() {
        let geometry = BarFieldGeometry(size: CGSize(width: 298, height: 169), unit: 1)
        let plain = geometry.barRect(slot: 1, depthMM: 52)
        let swollen = geometry.barRect(slot: 1, depthMM: 52, swell: 1)
        #expect(abs(swollen.width - geometry.slotWidth) < 1e-9)
        #expect(abs(swollen.midX - plain.midX) < 1e-9)
        #expect(swollen.maxY == plain.maxY)
    }

    @Test func ticksAreAllTheSameLength() {
        let geometry = BarFieldGeometry(size: CGSize(width: 298, height: 169), unit: 1)
        #expect(geometry.tickRect(slot: 1).height == Theme.metrics.tickLength)
        #expect(geometry.tickRect(slot: 9).height == geometry.tickRect(slot: 1).height)
        #expect(geometry.tickRect(slot: 1).width == geometry.barRect(slot: 1, depthMM: 40).width)
    }

    /// A pause is a stretch of time, not a depth, so its block runs through the line to the bottom of the field.
    /// No bar is ever that tall, which is what tells a pause from a push at a glance.
    @Test func aPauseBlockRunsUnbrokenFromTheRightEdgeAndThroughTheLine() {
        let geometry = BarFieldGeometry(size: CGSize(width: 298, height: 169), unit: 1)
        let block = geometry.blockRect(fromSlot: 0, toSlot: 7.5)
        #expect(block.maxX == geometry.plot.maxX)
        #expect(abs(block.width - 7.5 * geometry.slotWidth) < 1e-9)
        #expect(block.minY == geometry.plot.minY)
        #expect(block.maxY == geometry.plot.maxY)
        #expect(block.maxY > geometry.scale.y(Targets.adult.depthMaxMM))
    }

    @Test func theSessionRecordSharesTheLiveFieldsScale() {
        let live = BarFieldGeometry(size: CGSize(width: 298, height: 120), unit: 1)
        let record = SessionBarsLayout(size: CGSize(width: 826, height: 120 + Theme.metrics.axisLabelHeight),
                                       stats: HandoffStats(durationS: 60), unit: 1)
        #expect(record.scale == live.scale)
    }
}
