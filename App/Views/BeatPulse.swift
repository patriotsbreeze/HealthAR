import RescueAudio
import SwiftUI

/// The beat, in the target color, because it says where and when to act. Not tied to the audio clock,
/// so its phase may differ from the clicks, but the rate is the same.
struct BeatPulse: View {
    static let standardDiameter: CGFloat = DS.Pulse.standard
    static let label = "Push"

    var diameter = Self.standardDiameter
    var showsLabel = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let phase = time.truncatingRemainder(dividingBy: ClickGenerator.beatInterval) / ClickGenerator.beatInterval
            let strength = pow(1 - phase, 3)
            // A short band can give it less than it asked for, so it sizes itself from what it got.
            GeometryReader { geometry in
                let side = min(geometry.size.width, geometry.size.height)
                ZStack {
                    Circle().fill(DS.Colors.surface)
                    Circle().strokeBorder(DS.Colors.hairline, lineWidth: 1)
                    // Never below 0.84, so the label always sits on cyan.
                    Circle()
                        .fill(DS.Colors.target)
                        .padding(side * 0.07)
                        .scaleEffect(reduceMotion ? 1 : 0.84 + 0.16 * strength)
                    if reduceMotion {
                        // A flash on the beat at 1.83 Hz, with nothing moving.
                        Circle()
                            .strokeBorder(DS.Colors.ink.opacity(strength), lineWidth: max(2, side * 0.03))
                            .padding(side * 0.16)
                    }
                    if showsLabel {
                        Text(Self.label)
                            .font(.system(size: max(11, side * 0.19), weight: .bold))
                            .foregroundStyle(DS.Colors.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .padding(side * 0.2)
                    }
                }
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: diameter, maxHeight: diameter)
        .accessibilityElement()
        .accessibilityLabel("Compression beat, \(ClickGenerator.beatsPerMinute) per minute")
    }
}
