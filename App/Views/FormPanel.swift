import RescueVision
import SwiftUI

/// While pushing, the deck's main row: the form score over the last half minute, the rate, and the
/// one correction to make now. Read from the coordinator's tick; it keeps nothing of its own.
struct FormPanel: View {
    let reading: FormCoach.Reading

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 0) {
                Text(reading.score.map { "\($0)%" } ?? "--")
                    .dsFont(Self.score)
                    .foregroundStyle(scoreColor)
                    .contentTransition(.numericText())
                Text("Form")
                    .dsFont(DS.Fonts.meta)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            .frame(minWidth: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(cueText)
                    .dsFont(DS.Fonts.label)
                    .foregroundStyle(reading.cue == nil ? DS.Colors.textPrimary : DS.Colors.caution)
                    .fixedSize(horizontal: false, vertical: true)
                Text(reading.perMinute.map { "\($0) pushes a minute · aim 100 to 120" } ?? "Rate shows once pushing is seen")
                    .dsFont(DS.Fonts.meta)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.m)
        .background(DS.Glass.fill, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
        .animation(DS.Motion.deck, value: reading)
        .accessibilityElement(children: .combine)
    }

    static let score = DSFont(size: 40, weight: .bold, relativeTo: .largeTitle, monospacedDigits: true)

    private var cueText: String {
        if let cue = reading.cue { return ARSceneBuilder.coachingText(cue) }
        if reading.perMinute == nil { return "Point the camera at you and the patient" }
        return "Keep going"
    }

    private var scoreColor: Color {
        guard let score = reading.score else { return DS.Colors.textSecondary }
        return score >= 80 ? DS.Colors.ok : score >= 50 ? DS.Colors.caution : DS.Colors.critical
    }
}
