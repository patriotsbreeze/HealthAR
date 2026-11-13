import SwiftUI

/// One moving line of chest height in the quiet colour, over a faint band as tall as the threshold.
///
/// It draws only what it is handed; the line moves because the app hands it a newer trace a few times a second.
struct ChestTraceView: View {
    let values: [Double?]
    let band: ClosedRange<Double>?
    let bandShare: Double

    @Environment(\.plumbUnit) private var unit
    @Environment(\.plumbSurface) private var surface

    var body: some View {
        Canvas { context, size in
            let geometry = ChestTraceGeometry(size: size)
            let quiet = surface.quiet.color
            // A line beyond full scale leaves the plot and comes back, rather than lying flat along its edge.
            context.clip(to: Path(geometry.plot))
            if let band {
                let rect = geometry.bandRect(band, share: bandShare)
                context.fill(Path(rect), with: .color(quiet.opacity(Theme.chest.bandOpacity)))
            }
            let style = StrokeStyle(lineWidth: Theme.chest.traceWidth * unit, lineCap: .round, lineJoin: .round)
            for run in geometry.runs(values) {
                var path = Path()
                path.addLines(run)
                context.stroke(path, with: .color(quiet), style: style)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Chest height, newest on the right")
    }
}
