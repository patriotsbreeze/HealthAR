import SwiftUI

/// The right-hand panel of the chest screen: the headline, the trace, one line of context and two controls.
struct ChestPanel: View {
    let status: String
    let command: String?
    let context: String?
    let trace: [Double?]
    let band: ClosedRange<Double>?
    let bandShare: Double
    let onStartPushing: () -> Void
    let onBack: () -> Void

    @Environment(\.plumbUnit) private var unit

    var body: some View {
        let metrics = Theme.metrics
        VStack(alignment: .leading, spacing: 0) {
            ChestHeadline(status: status, command: command)
            ChestTraceView(values: trace, band: band, bandShare: bandShare)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, metrics.rowGap * unit)
            Text(context ?? "")
                .font(Theme.Face.text(.small, unit: unit))
                .foregroundStyle(Theme.Palette.quietOnGround.color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Theme.chest.contextHeight * unit)
                .accessibilityHidden(context == nil)
            Rectangle()
                .fill(Theme.Palette.quietOnGround.color.opacity(metrics.ruleOpacity))
                .frame(height: metrics.ruleWidth * unit)
            controls
        }
        .padding(.horizontal, metrics.panelPadding * unit)
        .padding(.top, metrics.topPadding * unit)
        .background(Theme.Palette.ground.color)
        .environment(\.plumbSurface, .ground)
    }

    /// The way on to the cushion, and the way back. "Back" is the lesser of the two, so it is quiet.
    private var controls: some View {
        HStack(spacing: 0) {
            PlainControl(title: "Start pushing", action: onStartPushing)
            Spacer(minLength: 0)
            PlainControl(title: "Back", tone: .quiet, leadsBack: true, action: onBack)
        }
        .frame(height: Theme.metrics.controlHeight * unit)
    }
}
