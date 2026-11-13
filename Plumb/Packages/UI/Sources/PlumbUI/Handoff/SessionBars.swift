import PlumbContracts
import SwiftUI

/// The whole session as bars: one column for each slice of time, pauses as accent blocks.
/// The same line and the same vertical scale as the live field, so a crew reads it the same way.
struct SessionBars: View {
    let stats: HandoffStats
    let targets: Targets

    @Environment(\.plumbUnit) private var unit
    @Environment(\.plumbSurface) private var surface

    var body: some View {
        let renderer = SessionBarsRenderer(surface: surface, unit: unit)
        Canvas { context, size in
            renderer.draw(stats, targets: targets, in: &context, size: size)
        }
        .accessibilityElement()
        .accessibilityLabel("The session as bars, one for each slice of time")
    }
}

/// Draws the session record. Holds no state.
struct SessionBarsRenderer {
    let surface: Theme.Surface
    let unit: CGFloat
    var metrics = Theme.metrics

    func draw(_ stats: HandoffStats, targets: Targets, in context: inout GraphicsContext, size: CGSize) {
        let painter = BarPainter(surface: surface, unit: unit, metrics: metrics)
        let layout = SessionBarsLayout(size: size, stats: stats, unit: unit, metrics: metrics)
        let targetY = layout.scale.y(targets.depthMinMM)
        let pauses = stats.pauses.map(layout.pauseRect)

        painter.drawTopRule(plot: layout.plot, in: &context)
        for bucket in stats.buckets {
            guard let column = layout.column(bucket, targets: targets) else { continue }
            // A pause is cut out of the slice it fell in: nobody was pushing then,
            // whatever the slice's typical depth says.
            for part in layout.standing(column, clearOf: pauses) {
                painter.draw(part.style, rect: part.rect, in: &context)
            }
        }
        painter.drawTargetLine(y: targetY, plot: layout.plot, in: &context)
        // A pause goes over the line and breaks it, as it broke the compressions.
        for rect in pauses {
            painter.drawBlock(rect, in: &context)
        }
        painter.drawDepthLabel(targets.depthMinMM, y: targetY, swatch: surface.mark, in: &context)
        drawTimeLabels(layout, pauses: zip(stats.pauses, pauses).map { ($0.durationS, $1) }, in: &context)
    }

    /// The start and end of the session under the two ends of the bars, and under each pause how long it lasted.
    private func drawTimeLabels(_ layout: SessionBarsLayout, pauses: [(seconds: Double, rect: CGRect)],
                                in context: inout GraphicsContext) {
        let y = layout.plot.maxY + metrics.axisLabelHeight * unit / 2
        let gap = metrics.labelGap * unit
        let unbounded = CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
        func label(_ words: String, _ swatch: Theme.Swatch) -> GraphicsContext.ResolvedText {
            context.resolve(Text(words).font(Theme.Face.numeral(.label, unit: unit)).foregroundStyle(swatch.color))
        }

        let start = label(Readout.elapsed(0), surface.quiet)
        let end = label(Readout.elapsed(layout.durationS), surface.quiet)
        context.draw(start, at: CGPoint(x: layout.plot.minX, y: y), anchor: .leading)
        context.draw(end, at: CGPoint(x: layout.plot.maxX, y: y), anchor: .trailing)

        // A pause's length is a measured number, so it is set at full strength; it yields to its neighbours.
        var taken = [layout.plot.minX...(layout.plot.minX + start.measure(in: unbounded).width),
                     (layout.plot.maxX - end.measure(in: unbounded).width)...layout.plot.maxX]
        for pause in pauses {
            let text = label(Readout.wholeSeconds(pause.seconds.rounded()) + Readout.unitSpace + "s", surface.mark)
            let width = text.measure(in: unbounded).width
            let span = (pause.rect.midX - width / 2 - gap)...(pause.rect.midX + width / 2 + gap)
            guard !taken.contains(where: { $0.overlaps(span) }) else { continue }
            context.draw(text, at: CGPoint(x: pause.rect.midX, y: y), anchor: .center)
            taken.append(span)
        }
    }
}

/// Where each slice of the session and each pause sits in the record.
struct SessionBarsLayout: Equatable {
    struct Column: Equatable {
        var rect: CGRect
        var style: BarStyle
    }

    let plot: CGRect
    let scale: DepthScale
    let axis: TimeAxis
    let durationS: Double
    private let barFill: CGFloat
    private let tickLength: CGFloat
    private let minimumPauseWidth: CGFloat
    private let pauseMargin: CGFloat
    private let sliverShare: CGFloat

    init(size: CGSize, stats: HandoffStats, unit: CGFloat, metrics: Theme.Metrics = Theme.metrics) {
        let gutter = min(metrics.fieldGutter * unit, size.width)
        let axisHeight = min(metrics.axisLabelHeight * unit, size.height)
        plot = CGRect(x: gutter, y: 0, width: size.width - gutter, height: size.height - axisHeight)
        scale = DepthScale(top: plot.minY, height: plot.height, fullScaleMM: metrics.fullScaleMM)
        // The slices are the record; the stated duration is only trusted when it covers them.
        let slicesEnd = stats.buckets.map { $0.start + $0.lengthS }.max() ?? 0
        durationS = max(stats.durationS, slicesEnd)
        axis = TimeAxis(minX: plot.minX, width: plot.width, window: 0...max(durationS, .leastNonzeroMagnitude))
        barFill = metrics.barFill
        tickLength = metrics.tickLength * unit
        minimumPauseWidth = metrics.minimumPauseWidth * unit
        pauseMargin = metrics.pauseMargin * unit
        sliverShare = metrics.sliverShare
    }

    /// The bar for one slice, or nil when nobody pushed during it.
    /// A slice with pushes but no trusted depth is a tick: the rhythm is known, the depth is not.
    func column(_ bucket: HandoffStats.Bucket, targets: Targets) -> Column? {
        guard bucket.compressions > 0 else { return nil }
        let minX = axis.x(bucket.start)
        let slot = axis.x(bucket.start + bucket.lengthS) - minX
        let width = slot * barFill
        let x = minX + (slot - width) / 2
        guard let depthMM = bucket.depthMM else {
            return Column(rect: CGRect(x: x, y: plot.minY, width: width, height: min(tickLength, plot.height)),
                          style: .tick)
        }
        return Column(rect: CGRect(x: x, y: plot.minY, width: width, height: scale.y(depthMM) - plot.minY),
                      style: depthMM >= targets.depthMinMM ? .reached : .short)
    }

    /// The block for one pause, at its true place in time and never too thin to see.
    /// It runs the whole height of the record, through the line, so it cannot be taken for a shallow push.
    func pauseRect(_ pause: HandoffStats.Pause) -> CGRect {
        let minX = axis.x(pause.start)
        let width = max(axis.x(pause.start + pause.durationS) - minX, minimumPauseWidth)
        return CGRect(x: min(minX, plot.maxX - width), y: plot.minY, width: width, height: plot.height)
    }

    /// What is left standing of a slice's bar once the pauses are cut out of it, each part kept clear
    /// of the pause by a margin. A part too thin to read as a bar is left out.
    func standing(_ column: Column, clearOf pauses: [CGRect]) -> [Column] {
        let whole = column.rect.minX...column.rect.maxX
        let gaps = pauses.map { ($0.minX - pauseMargin)...($0.maxX + pauseMargin) }.filter(whole.overlaps)
        // Most bars are nowhere near a pause, and are drawn exactly as they were laid out.
        guard !gaps.isEmpty else { return [column] }
        var parts = [whole]
        for gap in gaps {
            parts = parts.flatMap { part -> [ClosedRange<CGFloat>] in
                guard part.overlaps(gap) else { return [part] }
                var kept: [ClosedRange<CGFloat>] = []
                if gap.lowerBound > part.lowerBound { kept.append(part.lowerBound...gap.lowerBound) }
                if gap.upperBound < part.upperBound { kept.append(gap.upperBound...part.upperBound) }
                return kept
            }
        }
        let narrowest = column.rect.width * sliverShare
        return parts.filter { $0.upperBound - $0.lowerBound >= narrowest }.map { part in
            Column(rect: CGRect(x: part.lowerBound, y: column.rect.minY, width: part.upperBound - part.lowerBound,
                                height: column.rect.height),
                   style: column.style)
        }
    }
}
