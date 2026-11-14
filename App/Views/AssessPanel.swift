import RescueCore
import SwiftUI

/// The opening screen when there's an AI: the camera, one line, and what the AI thinks so far. Start
/// CPR and the dispatcher never wait on it, and a tap can always say what it hasn't worked out.
struct AssessPanel: View {
    let coordinator: AppCoordinator
    let onDispatcher: () -> Void
    @State private var tapping = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            status
            Text(coordinator.instruction)
                .dsFont(DS.Fonts.commandCompact)
                .foregroundStyle(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            thinking
            controls
            if tapping { tapRow.transition(.opacity) }
        }
        .padding(DS.Space.deckPadding)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: DS.Glass.deckRadius, style: .continuous), tint: DS.Glass.deckTint)
        .padding(.horizontal, DS.Space.deckInset)
        .padding(.bottom, DS.Space.xs)
        .animation(reduceMotion ? nil : DS.Motion.alert, value: coordinator.assessment)
        .animation(reduceMotion ? nil : DS.Motion.alert, value: tapping)
    }

    private var status: some View {
        HStack(spacing: DS.Space.s) {
            Circle()
                .fill(coordinator.liveConnected ? DS.Colors.ok : DS.Colors.textTertiary)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(coordinator.assessStatus)
                .dsFont(DS.Fonts.label)
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// What the AI has reported, in fixed words, and its last sentence apart from them.
    private var thinking: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("WHAT THE AI THINKS")
                .dsFont(DS.Fonts.badge)
                .foregroundStyle(DS.Colors.textTertiary)
                .accessibilityAddTraits(.isHeader)
            let notes = coordinator.assessment
            if notes.isEmpty {
                Text(coordinator.liveConnected ? "Nothing clear yet." : "Nothing yet.")
                    .dsFont(DS.Fonts.body)
                    .foregroundStyle(DS.Colors.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    ForEach(notes) { NoteRow(note: $0) }
                }
            }
            if let line = coordinator.lastAISentence {
                Text("AI: \u{201C}\(line)\u{201D}")
                    .dsFont(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(3)
                    .accessibilityLabel("The AI said: \(line)")
            }
            Text("Possibilities only. Not a diagnosis.")
                .dsFont(DS.Fonts.badge)
                .foregroundStyle(DS.Colors.textTertiary)
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
        }
        .buttonStyle(.plain)
    }

    private var dispatcher: some View {
        Button(action: onDispatcher) {
            Label("Mock 911", systemImage: "phone.fill")
                .dsFont(DS.Fonts.buttonCompact)
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, DS.Space.m)
                .frame(minHeight: DS.Height.camera)
                .background(DS.Glass.fill, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(DS.Glass.edge, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Call mock dispatcher. Places no call.")
    }

    private var tapInstead: some View {
        Button { tapping.toggle() } label: {
            HStack(spacing: 4) {
                Text(tapping ? "Hide" : "Tap instead")
                Image(systemName: tapping ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
            }
            .dsFont(DS.Fonts.label)
            .foregroundStyle(DS.Colors.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .frame(minHeight: DS.Height.camera)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Say what's happening with a tap instead of talking")
    }

    /// Only the two things a person can say that the AI may not: awake, or not.
    private var tapRow: some View {
        HStack(spacing: DS.Space.s) {
            tapChoice("Not responding", .patientUnresponsive)
            tapChoice("Awake and talking", .patientAwake)
        }
    }

    private func tapChoice(_ title: String, _ action: HumanAction) -> some View {
        Button { coordinator.perform(action) } label: {
            Text(title)
                .dsFont(DS.Fonts.buttonCompact)
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: DS.Height.camera)
                .background(DS.Glass.fill, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).strokeBorder(DS.Glass.edge, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct NoteRow: View {
    let note: AssessmentNote

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: note.source == .seen ? "eye" : "ear")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colors.textSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(note.label)
                .dsFont(DS.Fonts.prompt)
                .foregroundStyle(note.isUrgent ? DS.Colors.critical : DS.Colors.textPrimary)
            Text(note.certainty)
                .dsFont(DS.Fonts.caption)
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(note.label), \(note.certainty), \(note.source == .seen ? "seen" : "heard")")
    }
}
