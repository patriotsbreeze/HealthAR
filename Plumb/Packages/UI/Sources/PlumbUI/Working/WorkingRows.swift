import PlumbContracts
import SwiftUI

/// The three rows of the show-working screen: what was measured, what a model suggested, what the rules decided.
struct WorkingRows: View {
    let timeline: WorkingTimeline
    let targets: Targets
    @Binding var selection: WorkingSelection?

    @Environment(\.plumbUnit) private var unit

    var body: some View {
        // Only what falls inside the window is drawn, and only what is drawn can be selected.
        let shown = timeline.visible
        return GeometryReader { proxy in
            let layout = WorkingRowsLayout(size: proxy.size, window: shown.window, targets: targets, unit: unit)
            let renderer = WorkingRowsRenderer(unit: unit)
            Canvas { context, _ in
                renderer.draw(shown, targets: targets, selection: selection, layout: layout, in: &context)
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tap in
                selection = layout.selection(at: tap.location, in: shown)
            })
        }
        .accessibilityElement()
        .accessibilityLabel("Measured, suggested and decided, on one time axis")
        .accessibilityChildren {
            ForEach(shown.suggestions) { suggestion in
                Button("Suggested: \(suggestion.name)") { selection = .suggestion(suggestion.id) }
            }
            ForEach(shown.decisions) { decision in
                Button("\(decision.refused ? "Refused" : "Decided"): \(decision.label)") {
                    selection = .decision(decision.id)
                }
            }
        }
    }
}

/// Draws the three rows. Holds no state.
struct WorkingRowsRenderer {
    let unit: CGFloat
    var metrics = Theme.metrics

    private let surface = Theme.Surface.ground

    func draw(_ timeline: WorkingTimeline, targets: Targets, selection: WorkingSelection?,
              layout: WorkingRowsLayout, in context: inout GraphicsContext) {
        drawRowNames(timeline, layout: layout, in: &context)
        drawMeasured(timeline, targets: targets, layout: layout, in: &context)
        drawSuggested(timeline, selection: selection, layout: layout, in: &context)
        drawDecided(timeline, selection: selection, layout: layout, in: &context)
        if let selection, let cursor = layout.cursor(for: selection, in: timeline) {
            // One hairline down to the selected mark ties a decision to the pushes above it.
            let width = metrics.ruleWidth * unit
            let line = CGRect(x: cursor.x - width / 2, y: layout.measured.minY, width: width,
                              height: cursor.maxY - layout.measured.minY)
            context.fill(Path(line), with: .color(surface.mark.color))
        }
    }

    private func drawRowNames(_ timeline: WorkingTimeline, layout: WorkingRowsLayout,
                              in context: inout GraphicsContext) {
        let lineHeight = metrics.textSmall * unit * metrics.labelLeading
        context.draw(caption("Measured"), at: CGPoint(x: 0, y: layout.measured.minY), anchor: .topLeading)
        context.draw(caption(timeline.sampleRate), at: CGPoint(x: 0, y: layout.measured.minY + lineHeight),
                     anchor: .topLeading)
        context.draw(caption("Suggested"), at: CGPoint(x: 0, y: layout.lineY(0, in: layout.suggested)),
                     anchor: .leading)
        context.draw(caption("Decided"), at: CGPoint(x: 0, y: layout.lineY(0, in: layout.decided)),
                     anchor: .leading)
    }

    private func drawMeasured(_ timeline: WorkingTimeline, targets: Targets, layout: WorkingRowsLayout,
                              in context: inout GraphicsContext) {
        let painter = BarPainter(surface: surface, unit: unit, metrics: metrics)
        let targetY = layout.scale.y(targets.depthMinMM)
        painter.drawTopRule(plot: layout.measured, in: &context)
        for stroke in timeline.strokes {
            painter.draw(BarStyle(stroke.bar), rect: layout.strokeRect(stroke, tickLength: metrics.tickLength * unit),
                         in: &context)
        }
        painter.drawTargetLine(y: targetY, plot: layout.measured, in: &context)
        for pause in timeline.pauses {
            painter.drawBlock(layout.pauseRect(pause), in: &context)
        }
        painter.drawDepthLabel(targets.depthMinMM, y: targetY, swatch: surface.mark, in: &context)
    }

    /// Suggestions are drawn quietly: a model proposed them, and nothing here acts on a proposal alone.
    private func drawSuggested(_ timeline: WorkingTimeline, selection: WorkingSelection?, layout: WorkingRowsLayout,
                               in context: inout GraphicsContext) {
        let suggestions = timeline.suggestions.sorted { $0.start < $1.start }
        let labels = suggestions.map { suggestion in
            caption("\(suggestion.name) \(Readout.seconds(suggestion.durationS))",
                    selected: selection == .suggestion(suggestion.id))
        }
        let rects = suggestions.map(layout.spanRect)
        for (suggestion, rect) in zip(suggestions, rects) {
            drawMark(rect, solid: suggestion.ok, swatch: surface.quiet, in: &context)
        }
        drawLabels(labels, beside: rects, order: Array(suggestions.indices), lines: metrics.suggestedLines,
                   in: layout.suggested, layout: layout, context: &context)
    }

    private func drawDecided(_ timeline: WorkingTimeline, selection: WorkingSelection?, layout: WorkingRowsLayout,
                             in context: inout GraphicsContext) {
        let decisions = timeline.decisions.sorted { $0.t < $1.t }
        let labels = decisions.map { decision in
            decision.refused
                ? caption(decision.label, selected: selection == .decision(decision.id)).strikethrough()
                : Text(decision.label).font(Theme.Face.text(.small, unit: unit)).foregroundStyle(surface.mark.color)
        }
        let rects = decisions.map(layout.markRect)
        for (decision, rect) in zip(decisions, rects) {
            drawMark(rect, solid: !decision.refused, swatch: decision.refused ? surface.quiet : surface.mark,
                     in: &context)
        }
        // What the rules refused is the point of this row, so those labels are placed before the rest.
        let order = decisions.indices.filter { decisions[$0].refused } + decisions.indices.filter { !decisions[$0].refused }
        drawLabels(labels, beside: rects, order: order, lines: metrics.decidedLines,
                   in: layout.decided, layout: layout, context: &context)
    }

    private func drawLabels(_ labels: [Text], beside rects: [CGRect], order: [Int], lines: Int, in lane: CGRect,
                            layout: WorkingRowsLayout, context: inout GraphicsContext) {
        let resolved = labels.map { context.resolve($0) }
        let unbounded = CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
        let placements = LabelFit.placements(marks: rects.map { $0.minX...$0.maxX },
                                             labelWidths: resolved.map { $0.measure(in: unbounded).width },
                                             order: order, rows: lines, gap: metrics.labelGap * unit,
                                             bounds: lane.minX...lane.maxX)
        for (label, placement) in zip(resolved, placements) {
            guard let placement else { continue }
            context.draw(label, at: CGPoint(x: placement.x, y: layout.lineY(placement.row, in: lane)),
                         anchor: .leading)
        }
    }

    /// A span or a square. Solid when it stood; an outline when the call failed or the rules refused it.
    private func drawMark(_ rect: CGRect, solid: Bool, swatch: Theme.Swatch, in context: inout GraphicsContext) {
        let stroke = metrics.outlineWidth * unit
        if solid {
            context.fill(Path(rect), with: .color(swatch.color))
        } else {
            context.stroke(Path(rect.insetBy(dx: stroke / 2, dy: stroke / 2)), with: .color(swatch.color),
                           lineWidth: stroke)
        }
    }

    private func caption(_ words: String, selected: Bool = false) -> Text {
        Text(words)
            .font(Theme.Face.text(.small, unit: unit))
            .foregroundStyle(selected ? surface.mark.color : surface.quiet.color)
    }
}
