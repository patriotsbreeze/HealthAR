import PlumbContracts
import SwiftUI

/// The record handed to an arriving crew. The only light screen: dark text on paper.
///
/// It reads top to bottom: a headline, the session as bars, four measured numbers, what was not recorded,
/// and then, under a rule, any sentences that have already been checked.
public struct HandoffScreen: View {
    private let headline: String
    private let stats: HandoffStats
    private let depthRange: String?
    private let sentences: [String]
    private let targets: Targets
    private let onReadAloud: () -> Void
    private let onNewRescue: () -> Void

    /// A handoff page from values the app has already computed and checked.
    /// - Parameters:
    ///   - headline: the first line, such as "CPR started 14:02. Ran 6 min 40 s. 3 pauses, longest 9 s."
    ///   - stats: the measured summary. Nil fields read "not recorded".
    ///   - depthRange: the depth as a range, such as "48–56 mm", or nil when depth was not recorded.
    ///   - sentences: up to two sentences that have already been verified. Shown as given; none shows nothing.
    ///   - targets: where the line is drawn.
    ///   - onReadAloud: "Read aloud" was pressed.
    ///   - onNewRescue: "New rescue" was held until it confirmed.
    public init(headline: String,
                stats: HandoffStats,
                depthRange: String?,
                sentences: [String] = [],
                targets: Targets = .adult,
                onReadAloud: @escaping () -> Void,
                onNewRescue: @escaping () -> Void) {
        self.headline = headline
        self.stats = stats
        self.depthRange = depthRange
        self.sentences = Array(sentences.prefix(Theme.metrics.sentenceLimit))
        self.targets = targets
        self.onReadAloud = onReadAloud
        self.onNewRescue = onNewRescue
    }

    /// The page, laid out inside the safe area and scaled to the screen.
    public var body: some View {
        GeometryReader { proxy in
            // The unit comes from the whole screen, so safe-area margins inset the page without shrinking its type.
            let screen = CGSize(width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                                height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
            page(unit: ScreenPlan.unit(for: screen))
        }
        .background(Theme.Palette.paper.color.ignoresSafeArea())
        .environment(\.plumbSurface, .paper)
    }

    private func page(unit: CGFloat) -> some View {
        let metrics = Theme.metrics
        let ink = Theme.Palette.ground.color
        return VStack(alignment: .leading, spacing: 0) {
            Text(headline)
                .font(Theme.Face.numeral(.figure, unit: unit))
                .foregroundStyle(ink)
                .lineLimit(Theme.metrics.wrapLines)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            SessionBars(stats: stats, targets: targets)
                .frame(minHeight: metrics.sessionBarsMinHeight * unit, maxHeight: metrics.sessionBarsMaxHeight * unit)
                // Spare height goes to the record before it goes to empty space.
                .layoutPriority(1)
                .padding(.top, metrics.rowGap * unit)
            figures(unit: unit)
                .padding(.top, metrics.rowGap * unit)
            if !stats.notRecorded.isEmpty {
                Text("Not recorded: \(stats.notRecorded.joined(separator: ", ")).")
                    .font(Theme.Face.text(.small, unit: unit))
                    .foregroundStyle(ink)
                    .lineLimit(Theme.metrics.wrapLines)
                    .padding(.top, metrics.groupGap * unit)
            }
            Spacer(minLength: metrics.rowGap * unit)
            Rectangle()
                .fill(Theme.Palette.quietOnPaper.color.opacity(metrics.ruleOpacity))
                .frame(height: metrics.ruleWidth * unit)
            footer(unit: unit)
        }
        .padding(.horizontal, metrics.pagePadding * unit)
        .padding(.top, metrics.topPadding * unit)
        .padding(.bottom, metrics.rowGap * unit)
        .environment(\.plumbUnit, unit)
    }

    private func figures(unit: CGFloat) -> some View {
        HStack(alignment: .top, spacing: Theme.metrics.rowGap * unit) {
            HandoffFigure(value: stats.ratePerMin.map(Readout.rate), caption: "pushes a minute")
            HandoffFigure(value: depthRange, caption: "depth")
            HandoffFigure(value: stats.reachedTargetFraction.map(Readout.percent),
                          caption: "reached \(Readout.centimetres(targets.depthMinMM))")
            HandoffFigure(value: stats.handsOnFraction.map(Readout.percent), caption: "hands on chest")
        }
    }

    /// The checked sentences on the left, the two controls on the right, sharing one band under the rule.
    private func footer(unit: CGFloat) -> some View {
        let metrics = Theme.metrics
        return HStack(alignment: .center, spacing: metrics.pagePadding * unit) {
            VStack(alignment: .leading, spacing: metrics.tightGap * unit) {
                ForEach(Array(sentences.enumerated()), id: \.offset) { _, sentence in
                    Text(sentence)
                        .font(Theme.Face.text(.body, unit: unit))
                        .foregroundStyle(Theme.Palette.ground.color)
                        .lineLimit(Theme.metrics.wrapLines)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, metrics.rowGap * unit)
            .frame(maxWidth: .infinity, alignment: .leading)
            PlainControl(title: "Read aloud", action: onReadAloud)
            HoldToConfirm("New rescue", onConfirmed: onNewRescue)
        }
        .frame(minHeight: metrics.controlHeight * unit)
        // The band keeps its own height; the record above gives way instead.
        .fixedSize(horizontal: false, vertical: true)
    }
}
