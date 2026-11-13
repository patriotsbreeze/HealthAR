import PlumbContracts
import SwiftUI

/// "Show working": the depth picture on the left, and on the right what was measured, what a model
/// suggested and what the fixed rules decided, all on the bar axis of the rescue screen.
public struct WorkingScreen<DepthPicture: View>: View {
    private let timeline: WorkingTimeline
    private let scores: [WorkingScore]
    private let failsWhen: [String]
    private let targets: Targets
    private let onBack: () -> Void
    private let isRecording: Bool
    private let onRecordChanged: ((Bool) -> Void)?
    private let depthPicture: DepthPicture

    @State private var selection: WorkingSelection?

    /// A show-working screen from plain values.
    /// - Parameters:
    ///   - timeline: the three rows.
    ///   - scores: the scoreboard. The first three are shown.
    ///   - failsWhen: plain sentences naming the conditions this measurement fails in. The first four are shown.
    ///   - selected: the mark whose sentence is showing when the screen opens.
    ///   - targets: where the line is drawn.
    ///   - onBack: "Back" was pressed.
    ///   - isRecording: whether measurements are being recorded now, which decides what the record control says.
    ///   - onRecordChanged: when set, "Record measurements" or "Stop recording" stands beside "Back",
    ///     and is called with true to start recording and false to stop. Nil shows no record control.
    ///   - depthPicture: the depth picture. It is given a 4:3 frame.
    public init(timeline: WorkingTimeline,
                scores: [WorkingScore],
                failsWhen: [String],
                selected: WorkingSelection? = nil,
                targets: Targets = .adult,
                onBack: @escaping () -> Void,
                isRecording: Bool = false,
                onRecordChanged: ((Bool) -> Void)? = nil,
                @ViewBuilder depthPicture: () -> DepthPicture) {
        self.timeline = timeline
        self.scores = Array(scores.prefix(Theme.metrics.scoreLimit))
        self.failsWhen = Array(failsWhen.prefix(Theme.metrics.failsWhenLimit))
        self.targets = targets
        self.onBack = onBack
        self.isRecording = isRecording
        self.onRecordChanged = onRecordChanged
        self.depthPicture = depthPicture()
        _selection = State(initialValue: selected)
    }

    /// The record control, when the app can record.
    var recordControl: RecordControl? {
        onRecordChanged.map { RecordControl(isRecording: isRecording, onChange: $0) }
    }

    /// The picture column and the working column side by side, edge to edge.
    public var body: some View {
        // A reader that ignores the safe area is told the margins are zero, so an outer one asks first.
        GeometryReader { safe in
            GeometryReader { proxy in
                let plan = ScreenPlan(size: proxy.size, panelReferenceWidth: Theme.metrics.workingPanelWidth)
                HStack(alignment: .top, spacing: 0) {
                    pictureColumn(plan: plan)
                    workingColumn(unit: plan.unit)
                        // The picture may run under the home indicator; the scoreboard and the way back may not.
                        .padding(.bottom, safe.safeAreaInsets.bottom)
                }
                .environment(\.plumbUnit, plan.unit)
            }
            .background(Theme.Palette.ground.color)
            .ignoresSafeArea()
        }
        .environment(\.plumbSurface, .ground)
    }

    /// The depth picture, and under it the conditions it cannot be trusted in.
    private func pictureColumn(plan: ScreenPlan) -> some View {
        let metrics = Theme.metrics
        let unit = plan.unit
        return VStack(alignment: .leading, spacing: 0) {
            depthPicture
                .frame(width: plan.pictureSize.width, height: plan.pictureSize.height)
                .clipped()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: metrics.listGap * unit) {
                Text("Fails when")
                    .foregroundStyle(Theme.Palette.quietOnGround.color)
                ForEach(Array(failsWhen.enumerated()), id: \.offset) { _, condition in
                    Text(condition)
                        .foregroundStyle(Theme.Palette.paper.color)
                        .lineLimit(Theme.metrics.wrapLines)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(Theme.Face.text(.small, unit: unit))
            .padding(.horizontal, metrics.panelPadding * unit)
            .padding(.top, metrics.rowGap * unit)
            Spacer(minLength: 0)
        }
        .frame(width: plan.pictureSize.width)
    }

    private func workingColumn(unit: CGFloat) -> some View {
        let metrics = Theme.metrics
        return VStack(alignment: .leading, spacing: 0) {
            WorkingRows(timeline: timeline, targets: targets, selection: $selection)
                .frame(minHeight: metrics.workingRowsMinHeight * unit, maxHeight: metrics.workingRowsMaxHeight * unit)
                // Spare height goes to the rows before it goes to empty space.
                .layoutPriority(1)
            sentence(unit: unit)
            Spacer(minLength: 0)
            Rectangle()
                .fill(Theme.Palette.quietOnGround.color.opacity(metrics.ruleOpacity))
                .frame(height: metrics.ruleWidth * unit)
            footer(unit: unit)
        }
        .padding(.horizontal, metrics.panelPadding * unit)
        .padding(.top, metrics.topPadding * unit)
    }

    /// ONE sentence about the selected mark, at a size that can be read from where the screen is.
    private func sentence(unit: CGFloat) -> some View {
        let metrics = Theme.metrics
        let chosen = selection.flatMap(timeline.sentence)
        return Text(chosen ?? "Select a mark to read why.")
            .font(Theme.Face.text(chosen == nil ? .small : .body, unit: unit))
            .foregroundStyle(chosen == nil ? Theme.Palette.quietOnGround.color : Theme.Palette.paper.color)
            .lineLimit(Theme.metrics.wrapLines)
            .padding(.leading, metrics.rowLabelWidth * unit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: metrics.sentenceSlotHeight * unit)
            .padding(.vertical, metrics.tightGap * unit)
    }

    /// The scoreboard on the left, the way back on the right: the same band the handoff ends with.
    /// The record control, when there is one, stands just before the way back.
    private func footer(unit: CGFloat) -> some View {
        let metrics = Theme.metrics
        return HStack(alignment: .center, spacing: metrics.panelPadding * unit) {
            HStack(alignment: .top, spacing: metrics.rowGap * unit) {
                ForEach(Array(scores.enumerated()), id: \.offset) { _, score in
                    ScoreFigure(score: score)
                }
            }
            .padding(.vertical, metrics.rowGap * unit)
            recordControl
            PlainControl(title: "Back", leadsBack: true, action: onBack)
        }
        .frame(minHeight: metrics.controlHeight * unit)
        // The band keeps its own height; the rows above give way instead.
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One number of the scoreboard with the words that say what it counts.
private struct ScoreFigure: View {
    let score: WorkingScore

    @Environment(\.plumbUnit) private var unit

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(score.value)
                .font(Theme.Face.numeral(.figure, unit: unit))
                .foregroundStyle(Theme.Palette.paper.color)
                .lineLimit(1)
            Text(score.caption)
                .font(Theme.Face.text(.small, unit: unit))
                .foregroundStyle(Theme.Palette.quietOnGround.color)
                .lineLimit(Theme.metrics.wrapLines)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
