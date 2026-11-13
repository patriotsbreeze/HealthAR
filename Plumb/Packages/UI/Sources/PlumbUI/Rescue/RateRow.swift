import PlumbContracts
import SwiftUI

/// One number: the rate, large, in the accent only when it is out of range.
/// The elapsed time sits quietly at the far side. Before there is a rate, the place it will take
/// can hold "Check chest".
struct RateRow: View {
    let rate: Double?
    let rateInRange: Bool
    let elapsedSeconds: Double
    let model: BarFieldModel
    var onCheckChest: (() -> Void)?

    @Environment(\.plumbUnit) private var unit

    var body: some View {
        let quiet = Theme.Palette.quietOnGround.color
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // An unseen digit holds the row's baseline, so the elapsed time does not move when the rate comes or goes.
            Text("0")
                .font(Theme.Face.numeral(.large, unit: unit))
                .hidden()
                .frame(width: 0)
                .accessibilityHidden(true)
            // No rate is shown as no number at all, never as a zero or a dash that could be read as one.
            if let rate {
                Text(Readout.rate(rate))
                    .font(Theme.Face.numeral(.large, unit: unit))
                    .foregroundStyle(rateInRange ? Theme.Palette.paper.color : Theme.Palette.accent.color)
                    .accessibilityLabel("\(Readout.rate(rate)) per minute")
                Text("/min")
                    .font(Theme.Face.text(.body, unit: unit))
                    .foregroundStyle(quiet)
                    .padding(.leading, Theme.metrics.labelGap * unit)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: Theme.metrics.rowGap * unit)
            TrustCaption(model: model)
            Text(Readout.elapsed(elapsedSeconds))
                .font(Theme.Face.numeral(.small, unit: unit))
                .foregroundStyle(quiet)
                .padding(.leading, Theme.metrics.rowGap * unit)
                .accessibilityLabel("Elapsed \(Readout.elapsed(elapsedSeconds))")
        }
        .lineLimit(1)
        .frame(height: Theme.metrics.rateRowHeight * unit)
        // Laid over the row on its baseline, so nothing in the row moves when the control comes or goes.
        .overlay(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
            if rate == nil, let onCheckChest {
                PlainControl(title: "Check chest", action: onCheckChest)
            }
        }
    }
}

/// A few quiet words saying why the bars are drawn the way they are, when depth is not fully trusted.
///
/// The model is not observable, so this re-reads it a few times a second rather than every frame.
private struct TrustCaption: View {
    let model: BarFieldModel

    @Environment(\.plumbUnit) private var unit

    var body: some View {
        TimelineView(.periodic(from: .now, by: Theme.metrics.trustPollSeconds)) { _ in
            Text(words(for: model.trust))
                .font(Theme.Face.text(.small, unit: unit))
                .foregroundStyle(Theme.Palette.quietOnGround.color)
        }
    }

    private func words(for trust: LockState) -> String {
        switch trust {
        case .locked: ""
        case .estimating: "Estimating depth"
        case .rateOnly: "Rhythm only"
        case .lost: "Looking for hands"
        }
    }
}
