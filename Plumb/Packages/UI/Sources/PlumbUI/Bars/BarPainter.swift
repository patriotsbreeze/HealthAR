import SwiftUI

/// Draws the parts every bar picture is made of: the rule bars hang from, the two depth lines,
/// bars, and pause blocks. The live field and the records all go through it, so they cannot drift apart.
struct BarPainter {
    let surface: Theme.Surface
    let unit: CGFloat
    var metrics = Theme.metrics

    /// The rule along the top of the plot that bars hang from.
    func drawTopRule(plot: CGRect, in context: inout GraphicsContext) {
        let rule = CGRect(x: plot.minX, y: plot.minY, width: plot.width, height: metrics.ruleWidth * unit)
        context.fill(Path(rule), with: .color(surface.quiet.color.opacity(metrics.ruleOpacity)))
    }

    /// The hairline at the maximum depth.
    func drawMaximumLine(y: CGFloat, plot: CGRect, in context: inout GraphicsContext) {
        let width = metrics.hairlineWidth * unit
        let line = CGRect(x: plot.minX, y: y - width / 2, width: plot.width, height: width)
        context.fill(Path(line), with: .color(surface.quiet.color))
    }

    /// The line: the target minimum depth. `pulse` of 1 thickens it at the instant a push reaches it.
    func drawTargetLine(y: CGFloat, plot: CGRect, pulse: Double = 0, in context: inout GraphicsContext) {
        let width = (metrics.lineWidth + metrics.linePulseWidth * CGFloat(pulse)) * unit
        let line = CGRect(x: plot.minX, y: y - width / 2, width: plot.width, height: width)
        context.fill(Path(line), with: .color(surface.mark.color))
    }

    /// A depth label in the gutter left of the plot, centred on its line.
    func drawDepthLabel(_ depthMM: Double, y: CGFloat, swatch: Theme.Swatch, in context: inout GraphicsContext) {
        let label = Text(Readout.centimetres(depthMM))
            .font(Theme.Face.numeral(.label, unit: unit))
            .foregroundStyle(swatch.color)
        context.draw(label, at: CGPoint(x: 0, y: y), anchor: .leading)
    }

    /// True when the two depth lines are far enough apart for both to carry a label.
    func hasRoomForBothLabels(minimumY: CGFloat, maximumY: CGFloat) -> Bool {
        maximumY - minimumY >= metrics.numeralLabel * unit * metrics.labelLeading
    }

    /// One push.
    func draw(_ style: BarStyle, rect: CGRect, in context: inout GraphicsContext) {
        let shading = GraphicsContext.Shading.color(style.swatch(on: surface).color)
        let stroke = metrics.outlineWidth * unit
        if style == .outline, rect.height > stroke * 2, rect.width > stroke * 2 {
            context.stroke(Path(rect.insetBy(dx: stroke / 2, dy: stroke / 2)), with: shading, lineWidth: stroke)
        } else {
            context.fill(Path(rect), with: shading)
        }
    }

    /// A pause: a block in the accent, the one colour that means "fix this now".
    func drawBlock(_ rect: CGRect, in context: inout GraphicsContext) {
        context.fill(Path(rect), with: .color(Theme.Palette.accent.color))
    }

    /// The seconds a pause has lasted, set inside its block in the ground colour.
    /// A block still too narrow to hold the count goes without it rather than spill it over the bars.
    func drawPauseCount(seconds: Double, in block: CGRect, in context: inout GraphicsContext) {
        let ink = Theme.Palette.ground.color
        let count = Text(Readout.wholeSeconds(seconds)).font(Theme.Face.numeral(.large, unit: unit))
            + Text(Readout.unitSpace + "s").font(Theme.Face.numeral(.small, unit: unit))
        let inset = metrics.blockInset * unit
        let resolved = context.resolve(count.foregroundStyle(ink))
        let width = resolved.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width
        guard width + 2 * inset <= block.width else { return }
        context.draw(resolved, at: CGPoint(x: block.maxX - inset, y: block.maxY - inset), anchor: .bottomTrailing)
    }
}
