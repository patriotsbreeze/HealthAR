import RescueCore
import RescueLive
import SwiftUI

/// The opening screen when there's an AI. Start CPR and the 911 agent are first and never wait on
/// anything. Under them, three pills say what a bystander sees, each into one of the demo's two modes:
/// a collapse down the CPR path, or choking. The read above says what the AI thinks; here a person picks.
struct AssessPanel: View {
    let coordinator: AppCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Pill: Identifiable {
        let title: String
        let action: HumanAction
        /// The AI suggestions that ring this pill.
        var ringedBy: Set<SituationAssessment.Suggestion> = []
        var id: String { title }
    }

    /// Always these three, in this order. Collapsed asks about breathing next, as on every step.
    static let pills = [
        Pill(title: "Collapsed", action: .patientUnresponsive, ringedBy: [.notResponding]),
        Pill(title: "Not breathing", action: .patientNotBreathing, ringedBy: [.notBreathing]),
        Pill(title: "Choking", action: .triageChoking, ringedBy: [.choking]),
    ]

    /// The panel never takes more than this share of the screen, so the camera keeps the rest.
    static let maxScreenShare: CGFloat = 0.25
    /// On screen only. The spoken line, a recorded clip, says the longer version.
    static let shortInstruction = "What's happening?"
    /// The whole screen's height, from the main screen, for the cap.
    var screenHeight: CGFloat = 0

    var body: some View {
        CappedHeight(cap: screenHeight > 0 ? screenHeight * Self.maxScreenShare : .infinity) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text(Self.shortInstruction)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    status
                }
                HStack(spacing: 6) {
                    startCPR
                    dispatcher
                }
                pillRow(Self.pills)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s + 2)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        // The glass runs down into the home indicator's strip, as the deck's does, so no gap shows under it.
        .background {
            let shape = ConcentricRectangle(uniformTopCorners: .fixed(DS.Glass.deckRadius), uniformBottomCorners: .concentric(minimum: .fixed(DS.Glass.deckRadius)))
            Color.clear
                .glassSurface(shape, tint: DS.Glass.deckTint)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                .padding(.bottom, DS.Space.deckInset)
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .padding(.horizontal, DS.Space.deckInset)
        .animation(reduceMotion ? nil : DS.Motion.alert, value: suggestion)
    }


    private var status: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(coordinator.liveConnected ? DS.Colors.ok : DS.Colors.textTertiary)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(coordinator.liveConnected ? (coordinator.cameraLive ? "Live" : "Listening") : "Offline")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.Colors.textTertiary)
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(coordinator.assessStatus)
    }

    private func pillRow(_ pills: [Pill]) -> some View {
        HStack(spacing: 6) {
            ForEach(pills) { pill in
                let suggested = suggestion.map(pill.ringedBy.contains) ?? false
                let shape = Capsule(style: .continuous)
                Button { coordinator.perform(pill.action) } label: {
                    Text(pill.title)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, minHeight: DS.Height.camera)
                    .background(DS.Glass.fill, in: shape)
                    .overlay(shape.strokeBorder(DS.Glass.edge, lineWidth: 1))
                    .suggested(suggested, shape)
                }
                .buttonStyle(.plain)
                .accessibilityHint(suggested ? "The AI suggests this" : "")
            }
        }
    }

    private var startCPR: some View {
        Button { coordinator.perform(.startCpr) } label: {
            Label("Start CPR", systemImage: "heart.fill")
                .dsFont(DS.Fonts.buttonCompact)
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: DS.Height.camera)
                .background(DS.Colors.criticalFill, in: Capsule(style: .continuous))
                .suggested(suggestion == .startCpr, Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint(suggestion == .startCpr ? "The AI suggests this" : "")
    }

    private var dispatcher: some View {
        Button { coordinator.spawnCallerAgent() } label: {
            Label("Spawn 911 agent", systemImage: "phone.fill")
                .dsFont(DS.Fonts.buttonCompact)
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: DS.Height.camera)
                .background(DS.Glass.fill, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(DS.Glass.edge, lineWidth: 1))
                .suggested(suggestion == .callForHelp, Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Spawn 911 agent. A simulated call in the log. Places no call.")
        .accessibilityHint(suggestion == .callForHelp ? "The AI suggests this" : "")
    }

    /// The button the scene read points to, at medium or high confidence. It only ever highlights
    /// one of the fixed buttons, which stay where they are; nothing happens until a person taps.
    private var suggestion: SituationAssessment.Suggestion? { coordinator.assessSuggestion }

    static let suggestColor = Color.yellow
}

/// Offers its child no more height than the cap, and takes only what the child uses, so a short
/// panel stays short and a tall one is held to the cap.
private struct CappedHeight: Layout {
    let cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(capped(proposal))
        return CGSize(width: size.width, height: min(size.height, cap))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }

    private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width, height: min(proposal.height ?? cap, cap))
    }
}

extension View {
    /// A yellow ring round the one button the AI points to. It never moves or resizes the button.
    func suggested(_ on: Bool, _ shape: some InsettableShape) -> some View {
        overlay {
            if on {
                shape.strokeBorder(AssessPanel.suggestColor, lineWidth: 2.5)
                    .shadow(color: AssessPanel.suggestColor.opacity(0.7), radius: 6)
                    .allowsHitTesting(false)
            }
        }
    }
}
