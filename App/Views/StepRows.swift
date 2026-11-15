import RescueCore
import SwiftUI

/// Every tap here goes through the same calls as it always has: a step's own buttons wait out the
/// settle window through `performStep` or `performAnswer`, Start CPR through `performPrimary`, holds
/// and the way out through `perform`, and leaving CPR through the confirmation first.
struct AwakeRows: View {
    let coordinator: AppCoordinator
    /// A camera step needs the room for something to aim at. These are the tallest rows that can give any.
    var compact = false

    var body: some View {
        let layout = RescueControls.awakeLayout(coordinator.controls)
        VStack(spacing: DS.Space.betweenButtons) {
            if let suggestion = coordinator.flowSuggestion { suggestionLine(suggestion) }
            if !layout.answers.isEmpty {
                HStack(spacing: DS.Space.betweenButtons) {
                    ForEach(layout.answers) { stepButton($0, kind: .answer) }
                }
            }
            ForEach(layout.triage) { control in
                Button { coordinator.performStep(control.action) } label: {
                    HStack(spacing: DS.Space.m) {
                        Text(control.title)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }
                .buttonStyle(CommandButtonStyle(kind: .secondary, height: DS.Height.awake, alignment: .leading))
                .accessibilityLabel(control.title)
            }
            ForEach(pairs(layout.steps), id: \.first?.id) { pair in
                HStack(spacing: DS.Space.betweenButtons) {
                    ForEach(pair) { stepButton($0, kind: .primary) }
                }
            }
            ForEach(pairs(layout.holds), id: \.first?.id) { pair in
                HStack(spacing: DS.Space.betweenButtons) {
                    ForEach(pair) { control in
                        HoldButton(
                            title: control.title, hint: "Hold for 2 seconds.",
                            minHeight: compact ? DS.Height.camera : DS.Height.awakeHold,
                            font: compact ? DS.Fonts.buttonSmall : DS.Fonts.buttonCompact
                        ) {
                            coordinator.perform(control.action)
                        }
                        .fixedSize(horizontal: Self.hugs(control, in: pair), vertical: false)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            // The dispatcher and Someone is with me live in the rail's menu, so the deck is only the step.
            ForEach(layout.emsArrived) { control in
                HoldButton(title: control.title, hint: "Hold for 2 seconds.", minHeight: DS.Height.camera, font: DS.Fonts.buttonCompact) {
                    coordinator.perform(control.action)
                }
            }
        }
        .rowTypeCap()
    }

    /// Beside a long hold, like "Child, infant, drowning, or pregnant", a short one takes only the
    /// width its words need, so the long one wraps to two lines and not four. Same rows, so a camera
    /// step's band keeps its room.
    static func hugs(_ control: RescueControl, in pair: [RescueControl]) -> Bool {
        pair.count == 2 && control.title.count <= longHold && pair.contains { $0.title.count > longHold }
    }

    static let longHold = 20

    /// A new step puts different buttons here, so a tap aimed at the last step could answer this one.
    private func stepButton(_ control: RescueControl, kind: CommandButtonStyle.Kind) -> some View {
        let suggested = coordinator.flowSuggestion == control.action
        return Button(control.title) { coordinator.performStep(control.action) }
            .buttonStyle(CommandButtonStyle(kind: kind, height: DS.Height.awake))
            .suggested(suggested, RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
            .accessibilityLabel(control.title)
            .accessibilityHint(suggested ? "The AI suggests this. Say confirm or tap." : "")
    }

    /// What the AI thinks the answer is, over the buttons. Only a tap or "confirm" acts on it.
    private func suggestionLine(_ action: HumanAction) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AssessPanel.suggestColor)
            Text("AI suggests \(RescueControls.title(for: action))").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)
            Text("· say \u{201C}confirm\u{201D} or tap").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AssessPanel.suggestColor)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// Start CPR and Not responding now. Outside the scroll view and at the bottom of the deck, so it
/// never scrolls away and never moves: only the rows above change with the step, and they grow upward.
struct WayOutRow: View {
    let coordinator: AppCoordinator

    var body: some View {
        let layout = RescueControls.awakeLayout(coordinator.controls)
        // Start CPR takes the width its words need and Not responding now the rest, so neither wraps
        // where one line fits: at full size, then a size down on a small phone, and only past that
        // on two lines. The row's place and height never change.
        ViewThatFits(in: .horizontal) {
            row(layout, font: DS.Fonts.button, lineLimit: 1)
            row(layout, font: DS.Fonts.buttonTight, lineLimit: 1)
            row(layout, font: DS.Fonts.button, lineLimit: 2)
        }
        .rowTypeCap()
        .transaction { $0.animation = nil }
    }

    private func row(_ layout: RescueControls.AwakeLayout, font: DSFont, lineLimit: Int) -> some View {
        HStack(spacing: DS.Space.betweenButtons) {
            ForEach(layout.primary) { control in
                Button(control.title) { coordinator.perform(control.action) }
                    .buttonStyle(CommandButtonStyle(kind: .critical, height: DS.Height.awakeWayOut, font: font, lineLimit: lineLimit))
                    .fixedSize(horizontal: !layout.collapse.isEmpty, vertical: false)
                    .accessibilityLabel(control.title)
            }
            ForEach(layout.collapse) { control in
                Button(control.title) { coordinator.perform(control.action) }
                    .buttonStyle(CommandButtonStyle(kind: .criticalOutline, height: DS.Height.awakeWayOut, font: font, lineLimit: lineLimit))
                    .accessibilityLabel(control.title)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ArrestRows: View {
    let coordinator: AppCoordinator
    let onStopRequested: (RescueControl) -> Void

    var body: some View {
        let controls = coordinator.controls
        let inCPR = coordinator.definition?.kind == .cpr
        if inCPR, FormCoach.pushingStates.contains(coordinator.state.stateID) {
            pushingRows(controls)
        } else {
            rows(controls, inCPR: inCPR)
        }
    }

    /// While pushing, the deck is the form and the one way out: the crew is here and takes over.
    /// Everything else on these steps is said, not tapped.
    private func pushingRows(_ controls: [RescueControl]) -> some View {
        VStack(spacing: DS.Space.betweenButtons) {
            FormPanel(reading: coordinator.formReading)
            if let emsArrived = controls.first(where: { $0.action == .emsArrived && $0.role == .stopsCPR }) {
                HoldButton(title: "Stop CPR · EMS here", tone: .critical) { onStopRequested(emsArrived) }
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .rowTypeCap()
    }

    private func rows(_ controls: [RescueControl], inCPR: Bool) -> some View {
        VStack(spacing: DS.Space.betweenButtons) {
            // First, where it has always been, so a report that flips the screen lands it in the same place.
            ForEach(controls.filter { $0.role == .primary }) { control in
                Button(control.title) { coordinator.performPrimary(control.action) }
                    .buttonStyle(CommandButtonStyle(kind: .critical, height: DS.Height.arrestPrimary))
                    .accessibilityLabel(control.title)
            }
            let answers = [HumanAction.yes, .no, .unsure].compactMap { answer in
                controls.first { $0.action == answer }
            }
            if !answers.isEmpty {
                HStack(spacing: DS.Space.betweenButtons) {
                    ForEach(answers) { control in
                        Button(control.title) { coordinator.performAnswer(control.action) }
                            .buttonStyle(CommandButtonStyle(kind: .answer, height: DS.Height.arrest))
                            .accessibilityLabel(control.title)
                    }
                }
            }
            ForEach(pairs(controls.filter { $0.role == .step }), id: \.first?.id) { pair in
                HStack(spacing: DS.Space.betweenButtons) {
                    ForEach(pair) { control in
                        Button(control.title) { coordinator.perform(control.action) }
                            .buttonStyle(CommandButtonStyle(kind: CommandButtonStyle.kind(for: control, inCPR: inCPR), height: DS.Height.arrest))
                            .accessibilityLabel(control.title)
                    }
                }
            }
            ForEach(controls.filter { $0.role == .holdStep }) { control in
                HoldButton(title: control.title, hint: "Hold for 2 seconds.") { coordinator.perform(control.action) }
            }
            ForEach(pairs(controls.filter { $0.role == .stopsCPR }), id: \.first?.id) { pair in
                HStack(spacing: DS.Space.betweenButtons) {
                    ForEach(pair) { control in
                        HoldButton(title: control.title, tone: .critical) { onStopRequested(control) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .rowTypeCap()
    }
}

extension View {
    /// Button labels stop growing at the largest standard size. Past it a word like "responding"
    /// no longer fits half a row and breaks mid-word. The step above them keeps growing.
    func rowTypeCap() -> some View { dynamicTypeSize(...DynamicTypeSize.xxxLarge) }
}

/// A control left without a partner gets the whole row, which makes it easier to hit.
func pairs(_ controls: [RescueControl]) -> [[RescueControl]] {
    stride(from: 0, to: controls.count, by: 2).map { Array(controls[$0..<min($0 + 2, controls.count)]) }
}
