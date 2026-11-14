import SwiftUI

/// The 911 agent's call, running in the background while the rescuer gets on with CPR. It says the
/// call is simulated, because in this build nothing is dialed. A tap opens what was said.
struct CallerAgentPill: View {
    let status: AppCoordinator.CallerAgentStatus
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let callingLabel = "AI calling 911"
    static let doneLabel = "911 notified"
    static let simulated = "simulated"

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DS.Space.s) {
                icon
                Text(calling ? Self.callingLabel : Self.doneLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("\u{00B7} \(Self.simulated)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            .padding(.horizontal, DS.Space.m)
            .frame(minHeight: 36)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.7), lineWidth: 1.5))
            .lineLimit(1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(calling ? "AI calling 911 in the background, simulated" : "911 notified, simulated")
        .accessibilityHint("Shows what was said on the call.")
    }

    private var calling: Bool { status == .calling }
    private var tint: Color { calling ? .green : DS.Colors.textSecondary }

    @ViewBuilder private var icon: some View {
        if calling && !reduceMotion {
            TimelineView(.animation) { context in
                let pulse = (1 + sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.2)) / 2
                Image(systemName: "phone.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.green)
                    .scaleEffect(1 + 0.15 * pulse)
                    .opacity(0.6 + 0.4 * pulse)
            }
        } else {
            Image(systemName: calling ? "phone.fill" : "checkmark.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
        }
    }
}
