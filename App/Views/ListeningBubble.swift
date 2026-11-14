import SwiftUI

/// Shown only while the AI can hear or is talking, so a rescuer knows they can just talk. A sky orb with
/// clouds drifting through it and a soft glow that breathes, slowly while it listens and quicker while it
/// talks. Even talking it's slower than the cyan Push beat, and never its color, so the two can't mix up.
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
        HStack(spacing: DS.Space.m) {
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
                .dsFont(DS.Fonts.label)
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
                colors: [Self.sky.opacity(0.55), Self.sky.opacity(0)],
                center: .center,
                startRadius: DS.Listening.orb * 0.3,
                endRadius: DS.Listening.frame / 2
            ))
            .scaleEffect(0.85 + 0.25 * breath)
            .opacity((mode == .talking ? 0.7 : 0.55) + (mode == .talking ? 0.3 : 0.45) * breath)
            .blur(radius: 6)
    }

    /// Deep blue up top fading to pale at the bottom, with soft white clouds drifting across.
    private func orb(time: TimeInterval) -> some View {
        let side = DS.Listening.orb
        return ZStack {
            LinearGradient(colors: [Self.deep, Self.sky, Self.pale], startPoint: .topLeading, endPoint: .bottomTrailing)
            cloud(time: time, period: 9, width: 1.1, height: 0.55, x: 0.15, y: 0.25, drift: 0.18, opacity: 0.85)
            cloud(time: time, period: 13, width: 0.8, height: 0.45, x: -0.2, y: 0.05, drift: 0.22, opacity: 0.6)
            cloud(time: time, period: 7, width: 0.6, height: 0.3, x: 0.25, y: -0.1, drift: 0.15, opacity: 0.5)
            cloud(time: time, period: 11, width: 0.9, height: 0.35, x: -0.1, y: 0.4, drift: 0.2, opacity: 0.9)
            // A little light on the upper rim, so it reads as a sphere and not a flat disc.
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.35), .clear], center: UnitPoint(x: 0.3, y: 0.2), startRadius: 0, endRadius: side * 0.45))
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
    }

    /// One blurred white puff, wandering on a slow loop around where it starts.
    private func cloud(
        time: TimeInterval, period: TimeInterval, width: CGFloat, height: CGFloat,
        x: CGFloat, y: CGFloat, drift: CGFloat, opacity: Double
    ) -> some View {
        let side = DS.Listening.orb
        let angle = 2 * .pi * time / period
        return Ellipse()
            .fill(.white.opacity(opacity))
            .frame(width: side * width, height: side * height)
            .blur(radius: side * 0.09)
            .rotationEffect(.radians(sin(angle) * 0.25))
            .offset(x: side * (x + drift * sin(angle)), y: side * (y + drift * 0.5 * cos(angle * 0.8)))
    }

    private static let deep = Color(hex: 0x3B6FE0)
    private static let sky = Color(hex: 0x6E9BF2)
    private static let pale = Color(hex: 0xDCE8FC)
}
