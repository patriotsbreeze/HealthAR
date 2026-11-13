import RescueCore
import SwiftUI

/// One button family. Capsules, heights from the pinned table only, and a label that needs more room
/// grows the button rather than shrink past 0.85.
struct CommandButtonStyle: ButtonStyle {
    enum Kind: Equatable {
        /// The step's own action: Done, next, Called, Pads on.
        case primary
        case secondary
        /// Yes, No and Not sure.
        case answer
        /// Start CPR. Red means a life threat, and this is the answer to one.
        case critical
        /// Not responding now. The same meaning, but it asks first rather than starts.
        case criticalOutline
        /// The dispatcher and Someone is with me. Always there, never the step.
        case quiet
    }

    var kind: Kind
    var height: CGFloat
    var font: DSFont = DS.Fonts.button
    var alignment: Alignment = .center
    var lineLimit = 3
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dsFont(font)
            .multilineTextAlignment(alignment == .leading ? .leading : .center)
            .lineLimit(lineLimit)
            .minimumScaleFactor(0.85)
            // The pinned uppercase CALL MOCK DISPATCHER can't wrap mid-word, so it tightens before it would truncate.
            .allowsTightening(kind == .quiet)
            .foregroundStyle(label)
            .padding(.horizontal, max(DS.Space.l, height * 0.28))
            .padding(.vertical, DS.Space.xs)
            .frame(maxWidth: .infinity, minHeight: height, alignment: alignment)
            .background(fill, in: Capsule(style: .continuous))
            .overlay {
                if let edge {
                    Capsule(style: .continuous).strokeBorder(edge, lineWidth: kind == .criticalOutline ? 2 : 1)
                }
            }
            .contentShape(Capsule(style: .continuous))
            .brightness(configuration.isPressed ? (kind == .primary ? -0.12 : 0.08) : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(DS.Motion.press, value: configuration.isPressed)
            .opacity(isEnabled ? 1 : 0.4)
    }

    private var fill: Color {
        switch kind {
        case .primary: DS.Colors.primaryFill
        case .secondary, .answer, .criticalOutline: DS.Colors.surfaceRaised
        case .critical: DS.Colors.criticalFill
        case .quiet: .clear
        }
    }

    private var label: Color {
        kind == .primary ? DS.Colors.ink : DS.Colors.textPrimary
    }

    private var edge: Color? {
        switch kind {
        case .primary, .critical: nil
        case .secondary, .answer, .quiet: DS.Colors.hairline
        case .criticalOutline: DS.Colors.critical
        }
    }

    /// Action first, then role. During CPR pushing is the main thing, so a step there is secondary.
    static func kind(for control: RescueControl, inCPR: Bool) -> Kind {
        switch control.action {
        case .startCpr, .resumeCpr: return .critical
        case .patientUnresponsive: return .criticalOutline
        case .yes, .no, .unsure: return .answer
        case .metronomeOn, .metronomeOff, .shockDelivered: return .secondary
        case .triageChest, .triageLimb, .triageOther, .triageChoking: return .secondary
        case .secondPerson: return .quiet
        default: return inCPR ? .secondary : .primary
        }
    }
}

/// Runs its action only after a full 2 s hold. VoiceOver can't hold, so it gets a direct action.
struct HoldButton: View {
    enum Tone { case neutral, critical }

    static let holdSeconds = 2.0
    /// Says how, on the button itself, so nobody taps and waits.
    static let holdLine = "Hold 2 s"

    let title: String
    var hint = "Stops CPR. Hold for 2 seconds, then confirm."
    var minHeight: CGFloat = DS.Height.arrest
    var font: DSFont = DS.Fonts.button
    var tone = Tone.neutral
    let onHeld: () -> Void
    @State private var isPressing = false
    @State private var heldCount = 0

    var body: some View {
        ZStack {
            Capsule(style: .continuous).fill(DS.Colors.surfaceRaised)
            // Progress, not decoration, so Reduce Motion keeps it.
            GeometryReader { geometry in
                Rectangle()
                    .fill(tone == .critical ? DS.Colors.criticalFill : DS.Colors.holdSweep)
                    .frame(width: isPressing ? geometry.size.width : 0)
                    .animation(isPressing ? .linear(duration: Self.holdSeconds) : .easeOut(duration: 0.15), value: isPressing)
            }
            VStack(spacing: 2) {
                Text(title).dsFont(font)
                // Grey on the red sweep is about 2:1, so it goes white while held.
                Text(Self.holdLine)
                    .dsFont(DS.Fonts.meta)
                    .foregroundStyle(isPressing ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            }
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(0.85)
            .foregroundStyle(DS.Colors.textPrimary)
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.xs)
        }
        .clipShape(Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(tone == .critical ? DS.Colors.critical : DS.Colors.hairline, lineWidth: tone == .critical ? 2 : 1)
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .contentShape(Capsule(style: .continuous))
        .onLongPressGesture(minimumDuration: Self.holdSeconds, maximumDistance: 80) {
            heldCount += 1
            onHeld()
        } onPressingChanged: { isPressing = $0 }
        .sensoryFeedback(DS.Haptics.holdBegan, trigger: isPressing) { _, new in new }
        .sensoryFeedback(DS.Haptics.holdDone, trigger: heldCount)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityHint(hint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onHeld() }
    }
}
