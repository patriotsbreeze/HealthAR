import SwiftUI

/// The instrument. Every push is a bar that hangs from the top and either reaches the line or does not.
///
/// Redrawn every display frame from the model's plain properties, so the live bar follows the hands
/// without any SwiftUI state changing.
public struct BarField: View {
    private let model: BarFieldModel

    @Environment(\.plumbUnit) private var unit
    @Environment(\.plumbSurface) private var surface
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.barFieldStillDate) private var stillDate

    /// A field that draws whatever `model` holds, frame by frame.
    public init(model: BarFieldModel) {
        self.model = model
    }

    /// The field, redrawn once a display frame.
    public var body: some View {
        Group {
            if let stillDate {
                canvas(at: stillDate)
            } else {
                TimelineView(.animation) { timeline in
                    canvas(at: timeline.date)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Depth of each push against the target line")
    }

    private func canvas(at date: Date) -> some View {
        let frame = model.frame(at: date)
        let renderer = BarFieldRenderer(surface: surface, unit: unit, reduceMotion: reduceMotion)
        return Canvas { context, size in
            renderer.draw(frame, in: &context, size: size)
        }
    }
}

private struct StillDateKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

extension EnvironmentValues {
    /// When set, bar fields draw the single frame at this instant instead of running.
    /// For pictures of a chosen moment, such as the instant a push reaches the line.
    var barFieldStillDate: Date? {
        get { self[StillDateKey.self] }
        set { self[StillDateKey.self] = newValue }
    }
}
