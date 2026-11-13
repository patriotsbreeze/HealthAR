import CoreGraphics
import Foundation
import PlumbContracts

/// Where the three rows of the show-working screen sit, and what a tap on them selects.
/// All three share one time axis, so a mark lines up with the pushes that led to it.
struct WorkingRowsLayout: Equatable {
    /// The "Measured" row: bars on the same depth scale as the rescue screen.
    let measured: CGRect
    /// The "Suggested" lane: one span for each tool call.
    let suggested: CGRect
    /// The "Decided" lane: one mark for each cue or refusal.
    let decided: CGRect
    let axis: TimeAxis
    let scale: DepthScale
    private let lineHeight: CGFloat
    private let barWidth: CGFloat
    private let markSize: CGFloat
    private let hitSlop: CGFloat
    /// Half the gap between rows: how far above or below a lane a tap may land and still belong to it.
    private let laneSlop: CGFloat
    private let minimumPauseWidth: CGFloat
    private let pauseMargin: CGFloat

    init(size: CGSize, window: ClosedRange<TimeInterval>, targets: Targets, unit: CGFloat,
         metrics: Theme.Metrics = Theme.metrics) {
        let labelWidth = min(metrics.rowLabelWidth * unit, size.width)
        let gap = metrics.rowGap * unit
        let trackWidth = size.width - labelWidth
        lineHeight = metrics.laneLineHeight * unit
        let suggestedHeight = CGFloat(metrics.suggestedLines) * lineHeight
        let decidedHeight = CGFloat(metrics.decidedLines) * lineHeight
        let measuredHeight = max(0, size.height - suggestedHeight - decidedHeight - 2 * gap)

        measured = CGRect(x: labelWidth, y: 0, width: trackWidth, height: measuredHeight)
        suggested = CGRect(x: labelWidth, y: measured.maxY + gap, width: trackWidth, height: suggestedHeight)
        decided = CGRect(x: labelWidth, y: suggested.maxY + gap, width: trackWidth, height: decidedHeight)
        axis = TimeAxis(minX: labelWidth, width: trackWidth, window: window)
        scale = DepthScale(top: measured.minY, height: measured.height, fullScaleMM: metrics.fullScaleMM)

        // One beat of the target tempo is one slot, as on the rescue screen, however long the window is.
        let beats = (window.upperBound - window.lowerBound) * targets.beatPerMin / 60
        let slot = beats > 0 ? trackWidth / CGFloat(beats) : trackWidth
        barWidth = max(metrics.ruleWidth * unit, slot * metrics.barFill)
        markSize = metrics.markSize * unit
        hitSlop = metrics.hitSlop * unit
        laneSlop = gap / 2
        minimumPauseWidth = metrics.minimumPauseWidth * unit
        pauseMargin = metrics.pauseMargin * unit
    }

    /// The bar for one measured push, centred on the moment of its deepest point.
    func strokeRect(_ stroke: WorkingTimeline.Stroke, tickLength: CGFloat) -> CGRect {
        let height = BarStyle(stroke.bar) == .tick
            ? min(tickLength, measured.height)
            : scale.y(stroke.bar.depthMM) - measured.minY
        return CGRect(x: axis.x(stroke.t) - barWidth / 2, y: measured.minY, width: barWidth, height: height)
    }

    /// The block for one pause. A logged pause runs from the last push before it to the first after it,
    /// so the block sits between those two bars, clear of both, and runs through the line as no bar does.
    func pauseRect(_ pause: WorkingTimeline.Pause) -> CGRect {
        let span = span(from: pause.start, lasting: pause.durationS, inset: barWidth / 2 + pauseMargin,
                        atLeast: minimumPauseWidth)
        return CGRect(x: span.lowerBound, y: measured.minY, width: span.upperBound - span.lowerBound,
                      height: measured.height)
    }

    /// The middle of one of a lane's lines: 0 holds the marks, the rest hold labels that do not fit beside them.
    func lineY(_ row: Int, in lane: CGRect) -> CGFloat {
        lane.minY + lineHeight * (CGFloat(row) + 0.5)
    }

    /// The span for one tool call. Never narrower than a mark, so a fast call can still be seen and pressed.
    func spanRect(_ suggestion: WorkingTimeline.Suggestion) -> CGRect {
        let span = span(from: suggestion.start, lasting: suggestion.durationS, inset: 0, atLeast: markSize)
        return CGRect(x: span.lowerBound, y: lineY(0, in: suggested) - markSize / 2,
                      width: span.upperBound - span.lowerBound, height: markSize)
    }

    /// Where a stretch of time sits along the track: drawn in by `inset` at each end,
    /// cut at the window's edges, and at least `atLeast` wide.
    private func span(from start: TimeInterval, lasting durationS: Double, inset: CGFloat,
                      atLeast: CGFloat) -> ClosedRange<CGFloat> {
        let minX = max(axis.x(start) + inset, measured.minX)
        let maxX = min(axis.x(start + durationS) - inset, measured.maxX)
        let width = max(maxX - minX, atLeast)
        let leading = max(measured.minX, min(minX, measured.maxX - width))
        return leading...(leading + width)
    }

    /// The square for one decision, centred on its time.
    func markRect(_ decision: WorkingTimeline.Decision) -> CGRect {
        CGRect(x: axis.x(decision.t) - markSize / 2, y: lineY(0, in: decided) - markSize / 2,
               width: markSize, height: markSize)
    }

    /// The hairline for a selection: from the top of the measured row straight down to the selected mark.
    func cursor(for selection: WorkingSelection, in timeline: WorkingTimeline) -> (x: CGFloat, maxY: CGFloat)? {
        switch selection {
        case .suggestion(let id):
            timeline.suggestions.first { $0.id == id }.map(spanRect).map { ($0.minX, $0.maxY) }
        case .decision(let id):
            timeline.decisions.first { $0.id == id }.map(markRect).map { ($0.midX, $0.maxY) }
        }
    }

    /// What a tap at `point` selects, or nil when it lands on nothing.
    /// A label sits beside its mark, so a tap anywhere from a mark up to the next one belongs to that mark.
    func selection(at point: CGPoint, in timeline: WorkingTimeline) -> WorkingSelection? {
        if suggested.insetBy(dx: -hitSlop, dy: -laneSlop).contains(point) {
            let spans = timeline.suggestions.map { (id: $0.id, rect: spanRect($0)) }
            return owner(of: point.x, among: spans).map(WorkingSelection.suggestion)
        }
        if decided.insetBy(dx: -hitSlop, dy: -laneSlop).contains(point) {
            let marks = timeline.decisions.map { (id: $0.id, rect: markRect($0)) }
            return owner(of: point.x, among: marks).map(WorkingSelection.decision)
        }
        return nil
    }

    private func owner(of x: CGFloat, among items: [(id: Int, rect: CGRect)]) -> Int? {
        let sorted = items.sorted { $0.rect.minX < $1.rect.minX }
        if let atOrBefore = sorted.last(where: { $0.rect.minX - hitSlop <= x }) {
            return atOrBefore.id
        }
        return nil
    }
}
