import SwiftUI

/// Shown only while the AI can hear or is talking, so a rescuer knows they can just talk. The app's
/// pixel cross with a soft glow that breathes, slowly while it listens and quicker while it talks. Even
/// talking it's slower than the cyan Push beat, and never its color, so the two can't mix up.
struct ListeningBubble: View {
    enum Mode {
        case listening, talking

        var label: String {
            switch self {
            case .listening: "Listening…"
            case .talking: "Talking…"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .listening: "Listening. You can speak to the guide."
            case .talking: "The guide is talking."
            }
        }

        var breathSeconds: TimeInterval {
            switch self {
            case .listening: 3.2
            case .talking: 0.9
            }
        }

        /// How far the orb swells on each breath.
        var swell: CGFloat {
            switch self {
            case .listening: 0.03
            case .talking: 0.08
            }
        }
    }

    var mode = Mode.listening
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The words sit under the orb, so the read beside it gets the width.
        VStack(spacing: 0) {
            TimelineView(.animation(paused: reduceMotion)) { context in
                let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                let breath = (1 - cos(2 * .pi * time / mode.breathSeconds)) / 2
                ZStack {
                    glow(breath: breath)
                    orb(time: time)
                        .scaleEffect(1 + mode.swell * breath)
                }
                .frame(width: DS.Listening.frame, height: DS.Listening.frame)
            }
            Text(mode.label)
                .contentTransition(.opacity)
                .dsFont(DS.Fonts.caption)
                // The glow reaches the frame's edge, so the words tuck up under the orb itself.
                .padding(.top, -DS.Listening.labelTuck)
                .foregroundStyle(DS.Colors.textPrimary)
                .shadow(color: DS.Colors.ink.opacity(0.6), radius: 4)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mode.accessibilityLabel)
        .animation(DS.Motion.alert, value: mode)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    /// The haze around the orb, swelling and fading with each breath.
    private func glow(breath: Double) -> some View {
        Circle()
            .fill(RadialGradient(
                colors: [Self.glowColor.opacity(0.55), Self.glowColor.opacity(0)],
                center: .center,
                startRadius: DS.Listening.orb * 0.3,
                endRadius: DS.Listening.frame / 2
            ))
            .scaleEffect(0.85 + 0.25 * breath)
            .opacity((mode == .talking ? 0.7 : 0.55) + (mode == .talking ? 0.3 : 0.45) * breath)
            .blur(radius: 6)
    }

    /// The app's mark: a pixel red cross with eyes, on white, kept crisp at any size.
    private func orb(time: TimeInterval) -> some View {
        let side = DS.Listening.orb
        return Image("ListeningMark")
            .resizable()
            .interpolation(.none)
            .scaledToFill()
            .frame(width: side, height: side)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            .accessibilityHidden(true)
    }

    /// A soft red, from the cross, for the glow around it.
    private static let glowColor = Color(hex: 0xE63030)
}
