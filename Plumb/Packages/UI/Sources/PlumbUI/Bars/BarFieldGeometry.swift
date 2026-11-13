import CoreGraphics
import Foundation

/// Maps millimetres of travel to a vertical position. The live field and every record share it,
/// so a bar means the same thing wherever it is drawn.
struct DepthScale: Equatable {
    /// The y the bars hang from.
    let top: CGFloat
    /// The distance that `fullScaleMM` of travel covers.
    let height: CGFloat
    let fullScaleMM: Double

    /// The y a stroke of `depthMM` ends at. Deeper than full scale stops at the bottom edge.
    func y(_ depthMM: Double) -> CGFloat {
        let share = min(max(depthMM / fullScaleMM, 0), 1)
        return top + CGFloat(share) * height
    }
}

/// Maps a time in seconds to a horizontal position inside a record.
struct TimeAxis: Equatable {
    let minX: CGFloat
    let width: CGFloat
    let window: ClosedRange<TimeInterval>

    func x(_ t: TimeInterval) -> CGFloat {
        let length = window.upperBound - window.lowerBound
        guard length > 0 else { return minX }
        return minX + CGFloat((t - window.lowerBound) / length) * width
    }
}

/// Where the parts of the live bar field sit inside its bounds.
struct BarFieldGeometry: Equatable {
    /// The area bars are drawn in. Its top edge is the rule they hang from.
    let plot: CGRect
    let scale: DepthScale
    let slots: Int
    let barFill: CGFloat
    let tickLength: CGFloat

    init(size: CGSize, unit: CGFloat, metrics: Theme.Metrics = Theme.metrics) {
        let gutter = min(metrics.fieldGutter * unit, size.width)
        plot = CGRect(x: gutter, y: 0, width: size.width - gutter, height: size.height)
        scale = DepthScale(top: plot.minY, height: plot.height, fullScaleMM: metrics.fullScaleMM)
        slots = max(1, metrics.barSlots)
        barFill = metrics.barFill
        tickLength = metrics.tickLength * unit
    }

    var slotWidth: CGFloat {
        plot.width / CGFloat(slots)
    }

    /// The bar in a slot. Slots count leftwards from the right edge; slot 0 is the live bar.
    /// `swell` of 1 widens the bar to fill its slot, which is how a push that reached the line is emphasised.
    func barRect(slot: Double, depthMM: Double, swell: Double = 0) -> CGRect {
        column(slot: slot, swell: swell, height: scale.y(depthMM) - plot.minY)
    }

    /// The equal short tick drawn in a slot when only the rhythm is trusted.
    func tickRect(slot: Double) -> CGRect {
        column(slot: slot, swell: 0, height: min(tickLength, plot.height))
    }

    /// A pause: one unbroken block over a run of slots. It is a stretch of time, not a depth,
    /// so it runs the whole height of the field, through the line, as no bar ever does.
    func blockRect(fromSlot: Double, toSlot: Double) -> CGRect {
        let maxX = plot.maxX - CGFloat(fromSlot) * slotWidth
        let minX = plot.maxX - CGFloat(toSlot) * slotWidth
        return CGRect(x: minX, y: plot.minY, width: maxX - minX, height: plot.height)
    }

    private func column(slot: Double, swell: Double, height: CGFloat) -> CGRect {
        let fill = barFill + (1 - barFill) * CGFloat(min(max(swell, 0), 1))
        let width = slotWidth * fill
        let slotMinX = plot.maxX - CGFloat(slot + 1) * slotWidth
        return CGRect(x: slotMinX + (slotWidth - width) / 2, y: plot.minY, width: width, height: height)
    }
}
