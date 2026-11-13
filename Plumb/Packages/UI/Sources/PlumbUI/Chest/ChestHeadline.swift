import SwiftUI

/// The fixed-height slot at the top of the chest panel: the command once there is one, the status until then.
struct ChestHeadline: View {
    let status: String
    let command: String?

    @Environment(\.plumbUnit) private var unit

    var body: some View {
        ZStack(alignment: .leading) {
            if let command {
                // The command face never shrinks to fit, so a command wider than the panel takes two lines.
                Text(command.uppercased())
                    .font(Theme.Face.command(unit: unit))
                    .foregroundStyle(Theme.Palette.accent.color)
                    .lineLimit(Theme.metrics.wrapLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                    .accessibilityAddTraits(.isHeader)
            } else {
                Text(status)
                    .font(Theme.Face.numeral(.figure, unit: unit))
                    .foregroundStyle(Theme.Palette.paper.color)
                    .lineLimit(Theme.metrics.wrapLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Theme.chest.headlineHeight * unit)
        .animation(.linear(duration: Theme.metrics.fadeSeconds), value: command)
    }
}
