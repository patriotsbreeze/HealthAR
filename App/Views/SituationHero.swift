import RescueLive
import SwiftUI

/// The assess step's read of the scene, as the one big thing on the camera. While the AI works it's a
/// scanning line; once a read lands, what it sees goes large, an emergency in red above it, and what it
/// might be under it. A tap on an emergency, or "confirm", says it's real. After assess the small chip
/// takes over again, since then the deck leads.
struct SituationHero: View {
    let assessment: SituationAssessment?
    let assessing: Bool
    var failed = false
    /// What the rescuer confirmed, which keeps the card red after the reads move on.
    var confirmedEmergency: String?
    /// The button a confirm presses, when the AI rings one. Nil means it starts the 911 agent instead.
    var confirmTitle: String?
    var onConfirm: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A fresh read comes about every second, mostly the same scene in new words. Large type that
    /// rewords itself that often reads as jitter, so a read holds this long unless its meaning changes.
    static let holdTime: TimeInterval = 6
    /// The read on screen, which lags the newest one until it's worth swapping.
    @State private var shown: SituationAssessment?
    @State private var shownAt = Date.distantPast

    private var current: SituationAssessment? { shown ?? assessment }
    private var emergencyText: String? { confirmedEmergency ?? current?.emergency }
    private var isEmergency: Bool { emergencyText != nil }
    private var awaitingConfirm: Bool { confirmedEmergency == nil && current?.emergency != nil }
    private var accent: Color { isEmergency ? DS.Colors.critical : DS.Assessment.tint }

    var body: some View {
        Button(action: onConfirm) { card }
            .buttonStyle(.plain)
            .disabled(!awaitingConfirm)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint(awaitingConfirm ? (confirmTitle.map { "Confirms the emergency and presses \($0)." } ?? "Confirms the emergency and starts the simulated 911 agent.") : "")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            header
            if let current {
                read(current)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            } else {
                Text(failed && !assessing ? AssessmentChip.failedText : "Looking at the scene…")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                ScanLine(active: assessing && !reduceMotion, color: accent)
            }
            if isEmergency { confirmStrip.transition(.opacity) }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: DS.Assessment.heroRadius, style: .continuous)
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(DS.Assessment.heroFloor)
                shape.fill(LinearGradient(colors: [accent.opacity(0.28), accent.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .environment(\.colorScheme, .dark)
            .overlay(shape.strokeBorder(accent.opacity(isEmergency ? 0.9 : 0.55), lineWidth: isEmergency ? 2 : 1))
            .shadow(color: accent.opacity(0.35), radius: 16)
            .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
        }
        .animation(reduceMotion ? nil : DS.Motion.alert, value: shown)
        .animation(reduceMotion ? nil : DS.Motion.alert, value: assessing)
        .onAppear { take(assessment) }
        .onChange(of: assessment) { _, new in if shouldSwap(to: new) { take(new) } }
        // The moment a read lands, and again if it turns into an emergency.
        .sensoryFeedback(DS.Haptics.step, trigger: current != nil) { _, new in new }
        .sensoryFeedback(DS.Haptics.alert, trigger: isEmergency) { _, new in new }
        .sensoryFeedback(.success, trigger: confirmedEmergency != nil) { _, new in new }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    /// Asks for the tap while it's only the AI's word, and says what happened once a person agreed.
    private var confirmStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: awaitingConfirm ? "hand.tap.fill" : "checkmark.circle.fill")
                .font(.system(size: 17, weight: .bold))
            VStack(alignment: .leading, spacing: 1) {
                Text(awaitingConfirm ? (confirmTitle.map { "Tap to confirm: \($0)" } ?? "Tap to confirm emergency") : "Emergency confirmed")
                    .font(.system(size: 16, weight: .heavy))
                Text(awaitingConfirm ? "or say \u{201C}confirm\u{201D}" : "Help is being called · simulated, places no call")
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(0.85)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, DS.Space.s + 2)
        .padding(.vertical, DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.critical.opacity(awaitingConfirm ? 0.85 : 0.45), in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
    }

    private func take(_ read: SituationAssessment?) {
        shown = read
        shownAt = .now
    }

    /// Straight away when the read means something else: an emergency starts, ends or changes, the
    /// suggested button changes. Otherwise only once the last one has had its time.
    private func shouldSwap(to new: SituationAssessment?) -> Bool {
        guard let new, let old = shown else { return true }
        if new.emergency != old.emergency || new.suggests != old.suggests { return true }
        return Date.now.timeIntervalSince(shownAt) >= Self.holdTime
    }

    private var header: some View {
        HStack(spacing: 6) {
            PulsingSparkle(active: assessing, reduceMotion: reduceMotion, color: accent)
            Text(isEmergency ? "POSSIBLE EMERGENCY" : "AI SITUATION READ")
                .font(.system(size: 12, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(accent)
            Spacer(minLength: 0)
            if let assessment = current {
                Text(assessment.confidence.rawValue.capitalized)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(accent.opacity(0.35), in: Capsule(style: .continuous))
                    .accessibilityLabel("\(assessment.confidence.rawValue) confidence")
            }
        }
    }

    private func read(_ assessment: SituationAssessment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let emergency = emergencyText {
                Label(emergency, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(DS.Colors.critical)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            Text(assessment.sees ?? assessment.headline)
                .font(.system(size: emergencyText == nil ? 26 : 19, weight: .bold))
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .contentTransition(.opacity)
            Text(assessment.prediction)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Colors.textSecondary)
                .lineLimit(2)
                .contentTransition(.opacity)
            Text(AssessmentChip.footnote)
                .font(.system(size: 10))
                .foregroundStyle(DS.Colors.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 2)
        }
    }
}

/// A sparkle that breathes while the AI works, and sits still once the read is in.
private struct PulsingSparkle: View {
    let active: Bool
    let reduceMotion: Bool
    let color: Color

    var body: some View {
        TimelineView(.animation(paused: !active || reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let pulse = active && !reduceMotion ? (1 - cos(2 * .pi * time / 1.2)) / 2 : 1
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(color)
                .opacity(0.45 + 0.55 * pulse)
                .scaleEffect(0.88 + 0.12 * pulse)
        }
        .frame(width: 18)
        .accessibilityHidden(true)
    }
}

/// A bar of light sweeping across, so it reads as the AI looking rather than the app hanging.
private struct ScanLine: View {
    let active: Bool
    let color: Color

    var body: some View {
        TimelineView(.animation(paused: !active)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            GeometryReader { proxy in
                let width = proxy.size.width
                Capsule().fill(color.opacity(0.18))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(LinearGradient(colors: [color.opacity(0), color, color.opacity(0)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: width * 0.35)
                            .offset(x: active ? (width * 1.35) * phase - width * 0.35 : 0)
                    }
                    .clipShape(Capsule())
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
