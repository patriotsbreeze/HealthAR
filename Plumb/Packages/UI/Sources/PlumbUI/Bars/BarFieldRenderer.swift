import SwiftUI

/// Draws one frame of the live bar field from a copied-out frame. Holds no state of its own.
struct BarFieldRenderer {
    let surface: Theme.Surface
    let unit: CGFloat
    let reduceMotion: Bool
    var metrics = Theme.metrics

    func draw(_ frame: BarFieldFrame, in context: inout GraphicsContext, size: CGSize) {
        let geometry = BarFieldGeometry(size: size, unit: unit, metrics: metrics)
        let layout = BarFieldLayout(frame: frame, slots: geometry.slots, reduceMotion: reduceMotion, metrics: metrics)
        let painter = BarPainter(surface: surface, unit: unit, metrics: metrics)
        let targetY = geometry.scale.y(frame.targets.depthMinMM)
        let maximumY = geometry.scale.y(frame.targets.depthMaxMM)

        painter.drawTopRule(plot: geometry.plot, in: &context)
        painter.drawMaximumLine(y: maximumY, plot: geometry.plot, in: &context)

        // Bars stepping in or out at the left edge are cut by the plot, never drawn over the labels.
        var plot = context
        plot.clip(to: Path(geometry.plot))
        for stroke in layout.strokes {
            let style = BarStyle(stroke.bar)
            let rect = style == .tick
                ? geometry.tickRect(slot: stroke.slot)
                : geometry.barRect(slot: stroke.slot, depthMM: stroke.bar.depthMM, swell: stroke.swell)
            painter.draw(style, rect: rect, in: &plot)
        }
        if layout.showsLiveBar {
            // The live bar is never judged: it is solid when trusted and an outline when not.
            let style: BarStyle = frame.trust == .locked ? .reached : .outline
            painter.draw(style, rect: geometry.barRect(slot: 0, depthMM: frame.liveDepthMM), in: &plot)
        }

        // The line goes over the bars so it reads as one unbroken edge they meet.
        painter.drawTargetLine(y: targetY, plot: geometry.plot, pulse: layout.linePulse, in: &context)
        painter.drawDepthLabel(frame.targets.depthMinMM, y: targetY, swatch: surface.mark, in: &context)
        if painter.hasRoomForBothLabels(minimumY: targetY, maximumY: maximumY) {
            painter.drawDepthLabel(frame.targets.depthMaxMM, y: maximumY, swatch: surface.quiet, in: &context)
        }

        // A pause goes over everything, the line included: while nobody pushes there is no line to reach.
        for block in layout.blocks {
            let rect = geometry.blockRect(fromSlot: block.fromSlot, toSlot: block.toSlot)
            painter.drawBlock(rect, in: &plot)
            if block.isCurrent {
                painter.drawPauseCount(seconds: block.seconds, in: rect, in: &plot)
            }
        }
    }
}
