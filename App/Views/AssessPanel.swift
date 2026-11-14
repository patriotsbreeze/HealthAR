import RescueCore
import RescueLive
import SwiftUI

/// The opening screen when there's an AI: the camera, one line, and what the AI thinks so far. Start
/// CPR and the dispatcher never wait on it, and a tap can always say what it hasn't worked out.
struct AssessPanel: View {
    let coordinator: AppCoordinator
    let onDispatcher: () -> Void
    @State private var tapping = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The panel never takes more than this share of the screen, so the camera keeps the rest.
    static let maxScreenShare: CGFloat = 0.25
    /// On screen only. The spoken line, a recorded clip, says the longer version.
    static let shortInstruction = "Aim at them. Say what happened."
    /// More would push the buttons up into the camera. The newest are first.
    static let maxNotes = 2
    /// The whole screen's height, from the main screen, for the cap.
    var screenHeight: CGFloat = 0

    var body: some View {
        // Each layout drops the least needed part first, so Start CPR and the dispatcher always fit.
        // Hugs its content, and only drops parts when that would go past the cap.
        CappedHeight(cap: screenHeight > 0 ? screenHeight * Self.maxScreenShare : .infinity) {
            ViewThatFits(in: .vertical) {
                layout(showsNotes: true, showsLine: true)
                layout(showsNotes: true, showsLine: false)
                layout(showsNotes: false, showsLine: false)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s + 2)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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
        .animation(reduceMotion ? nil : DS.Motion.alert, value: coordinator.assessment)
        .animation(reduceMotion ? nil : DS.Motion.alert, value: tapping)
    }

    private func layout(showsNotes: Bool, showsLine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
            if showsNotes { thinking(showsLine: showsLine) }
            if let suggestion { suggestionLine(suggestion) }
            controls
            if tapping { tapRow.transition(.opacity) }
        }
        .fixedSize(horizontal: false, vertical: true)
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

    /// What the AI has reported, in fixed words, and its last sentence apart from them.
    private func thinking(showsLine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            let notes = coordinator.assessment.prefix(Self.maxNotes)
            if notes.isEmpty {
                Text(coordinator.liveConnected ? "Nothing clear yet." : "Nothing yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.textSecondary)
            } else {
                ForEach(Array(notes)) { NoteRow(note: $0) }
            }
            if showsLine, let line = coordinator.lastAISentence {
                Text("AI: \u{201C}\(line)\u{201D}")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .accessibilityLabel("The AI said: \(line)")
            }
        }
    }

    /// Start CPR and the dispatcher never shrink or cut off. Where the row is too narrow for all three,
    /// Tap instead goes under them.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.s) {
                startCPR
                dispatcher
                Spacer(minLength: DS.Space.s)
                tapInstead
            }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(spacing: DS.Space.s) {
                    startCPR
                    dispatcher
                }
                tapInstead
            }
        }
    }

    private var startCPR: some View {
        Button { coordinator.perform(.startCpr) } label: {
            Label("Start CPR", systemImage: "heart.fill")
                .dsFont(DS.Fonts.buttonCompact)
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, DS.Space.m)
                .frame(minHeight: DS.Height.camera)
                .background(DS.Colors.criticalFill, in: Capsule(style: .continuous))
                .suggested(suggestion == .startCpr, Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint(suggestion == .startCpr ? "The AI suggests this" : "")
    }

    private var dispatcher: some View {
        Button(action: onDispatcher) {
            Label("911 script", systemImage: "phone.fill")
                .dsFont(DS.Fonts.buttonCompact)
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, DS.Space.m)
                .frame(minHeight: DS.Height.camera)
                .background(DS.Glass.fill, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(DS.Glass.edge, lineWidth: 1))
                .suggested(suggestion == .callForHelp, Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("911 script: what to tell the dispatcher. Places no call.")
        .accessibilityHint(suggestion == .callForHelp ? "The AI suggests this" : "")
    }

    /// An icon, so it shares the row with Start CPR and the dispatcher instead of taking its own.
    private var tapInstead: some View {
        Button { tapping.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: "hand.tap")
                    .font(.system(size: 15, weight: .semibold))
                Image(systemName: tapping ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(DS.Colors.textSecondary)
            .frame(minWidth: DS.Height.camera, minHeight: DS.Height.camera)
            .contentShape(Rectangle())
            .suggested(!tapping && suggestion?.isTapChoice == true, RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tapping ? "Hide tap choices" : "Tap instead")
        .accessibilityHint("Say what's happening with a tap instead of talking")
    }

    /// The things a person can say that the AI may not: whether they respond, whether they're
    /// breathing normally, and whether they're awake. Always these three, in this order.
    private var tapRow: some View {
        HStack(spacing: DS.Space.s) {
            tapChoice("Not responding", .patientUnresponsive, suggested: suggestion == .notResponding)
            tapChoice("Not breathing or gasping", .patientNotBreathing, suggested: suggestion == .notBreathing)
            tapChoice("Awake and talking", .patientAwake, suggested: suggestion == .awake)
        }
    }

    private func tapChoice(_ title: String, _ action: HumanAction, suggested: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
        return Button { coordinator.perform(action) } label: {
            Text(title)
                .dsFont(DS.Fonts.buttonCompact)
                .foregroundStyle(DS.Colors.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, minHeight: DS.Height.camera)
                .background(DS.Glass.fill, in: shape)
                .overlay(shape.strokeBorder(DS.Glass.edge, lineWidth: 1))
                .suggested(suggested, shape)
        }
        .buttonStyle(.plain)
        .accessibilityHint(suggested ? "The AI suggests this" : "")
    }

    /// The button the scene read points to, at medium or high confidence. It only ever highlights
    /// one of the fixed buttons, which stay where they are; nothing happens until a person taps.
    private var suggestion: SituationAssessment.Suggestion? { coordinator.assessSuggestion }

    private func suggestionLine(_ suggestion: SituationAssessment.Suggestion) -> some View {
        let reason = coordinator.sceneRead?.sees ?? coordinator.sceneRead?.headline
        return HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.suggestColor)
            Text("AI suggests \(suggestion.buttonTitle)").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)
            if suggestion.confirmAction != nil {
                Text("· say \u{201C}confirm\u{201D} or tap").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Self.suggestColor)
            }
            if let reason {
                Text("· \(reason)").font(.system(size: 12))
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    static let suggestColor = Color.yellow
}

private struct NoteRow: View {
    let note: AssessmentNote

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: note.source == .seen ? "eye" : "ear")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Colors.textSecondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(note.label)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(note.isUrgent ? DS.Colors.critical : DS.Colors.textPrimary)
            Text(note.certainty)
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(note.label), \(note.certainty), \(note.source == .seen ? "seen" : "heard")")
    }
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

private extension SituationAssessment.Suggestion {
    var buttonTitle: String {
        switch self {
        case .startCpr: "Start CPR"
        case .notResponding: "Not responding"
        case .notBreathing: "Not breathing"
        case .awake: "Awake and talking"
        case .callForHelp: "911 script"
        }
    }

    /// Behind Tap instead, so the toggle glows while the row is shut.
    var isTapChoice: Bool { self == .notResponding || self == .notBreathing || self == .awake }
}

private extension View {
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
