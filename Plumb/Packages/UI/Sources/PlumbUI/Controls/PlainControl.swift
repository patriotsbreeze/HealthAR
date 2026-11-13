import SwiftUI

/// A control that is nothing but its words: no border, no fill, a generous place to press.
struct PlainControl: View {
    /// Which of the palette's meanings the words carry.
    enum Tone {
        /// An ordinary action.
        case mark
        /// A lesser action that should not compete.
        case quiet
        /// The AED, and only the AED.
        case aed
    }

    let title: String
    var tone: Tone = .mark
    /// Draws a plain chevron before the words, for the one control that goes back.
    var leadsBack = false
    let action: () -> Void

    @Environment(\.plumbUnit) private var unit
    @Environment(\.plumbSurface) private var surface

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.metrics.labelGap * unit) {
                if leadsBack {
                    Chevron()
                        .stroke(color, style: StrokeStyle(lineWidth: Theme.metrics.outlineWidth * unit,
                                                         lineCap: .round, lineJoin: .round))
                        .frame(width: Theme.metrics.chevronSize.width * unit, height: Theme.metrics.chevronSize.height * unit)
                }
                Text(title)
                    .font(Theme.Face.text(.body, unit: unit))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(color)
            .frame(minHeight: Theme.metrics.controlHeight * unit)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainWordStyle())
    }

    private var color: Color {
        switch tone {
        case .mark: surface.mark.color
        case .quiet: surface.quiet.color
        case .aed: Theme.Palette.aed.color
        }
    }
}

/// The only press feedback a plain-word control gives: it dims while pressed.
private struct PlainWordStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? Theme.metrics.pressedOpacity : 1)
    }
}

/// A plain chevron pointing left. The only pictogram in the app.
private struct Chevron: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}
