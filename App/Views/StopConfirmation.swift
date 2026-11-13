import RescueCore
import SwiftUI

/// The second half of leaving CPR, after the hold. The system dialog's buttons are too small for
/// gloved hands.
struct StopConfirmation: View {
    static let caution = "Only stop if this is true. Otherwise keep pushing."
    static let cancelTitle = "No, keep pushing"

    let control: RescueControl
    let showsPulse: Bool
    var operatorUsed = false
    var onOperator: (() -> Void)?
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            SimulationStrip(operatorUsed: operatorUsed, onOperator: onOperator)
            VStack(alignment: .leading, spacing: DS.Space.l) {
                if showsPulse {
                    // The beat stays up: until this is confirmed, pushing goes on. It says so, as on the main screen.
                    BeatPulse(diameter: DS.Pulse.confirmation)
                }
                Spacer(minLength: 0)
                Text(control.confirmationTitle)
                    .dsFont(DS.Fonts.confirm)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(Self.caution)
                    .dsFont(DS.Fonts.detail)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.xl)
                // Keep pushing is the bigger one and comes first, so a slip lands on the safe answer.
                Button(Self.cancelTitle, action: onCancel)
                    .buttonStyle(CommandButtonStyle(kind: .primary, height: DS.Height.stopCancel))
                Button("Yes, stop CPR: \(control.title)", action: onConfirm)
                    .buttonStyle(CommandButtonStyle(kind: .critical, height: DS.Height.stopConfirm))
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .background(DS.Colors.canvas.ignoresSafeArea())
        .accessibilityAddTraits(.isModal)
        // A change of value is what plays it, so it's set once the screen is up.
        .sensoryFeedback(DS.Haptics.stopAsked, trigger: shown)
        .onAppear { shown = true }
        .transition(.opacity)
    }
}
