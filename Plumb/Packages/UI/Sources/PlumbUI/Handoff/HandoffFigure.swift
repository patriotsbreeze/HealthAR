import SwiftUI

/// One number of the handoff with the words that finish its sentence, such as "112 / pushes a minute, measured".
/// A missing value reads "not recorded" at full strength: an absent number is a fact, not a detail.
struct HandoffFigure: View {
    /// The number as it should be read, or nil when it was not recorded.
    let value: String?
    /// What the number counts, in plain words that follow on from it.
    let caption: String
    /// Where the number came from, in one plain word.
    var source = "measured"

    @Environment(\.plumbUnit) private var unit
    @Environment(\.plumbSurface) private var surface

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value ?? "not recorded")
                .font(Theme.Face.numeral(.figure, unit: unit))
                .foregroundStyle(surface.mark.color)
                .lineLimit(1)
            // A source is only named for a number that exists.
            Text(value == nil ? caption : "\(caption), \(source)")
                .font(Theme.Face.text(.small, unit: unit))
                .foregroundStyle(surface.quiet.color)
                .lineLimit(Theme.metrics.wrapLines)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
