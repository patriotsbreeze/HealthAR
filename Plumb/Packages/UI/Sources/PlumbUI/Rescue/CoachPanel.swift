import SwiftUI

/// The right-hand panel of the rescue screen: the command, the bars, the rate, and three plain-word controls.
public struct CoachPanel: View {
    private let command: String?
    private let tone: CommandTone
    private let startPrompt: String?
    private let model: BarFieldModel
    private let rate: Double?
    private let rateInRange: Bool
    private let elapsedSeconds: Double
    private let onAskChanged: (Bool) -> Void
    private let onFindAED: () -> Void
    private let onShowWorking: () -> Void
    private let onHandOver: (() -> Void)?
    private let onCheckChest: (() -> Void)?

    @Environment(\.plumbUnit) private var unit

    /// A panel showing the values it is given. It keeps no state of its own beyond the bars' model.
    /// - Parameters:
    ///   - command: the one command to show, or nil when nothing needs saying. Drawn in upper case.
    ///   - tone: whether the command is a correction or an affirmation such as "GOOD".
    ///   - startPrompt: the first instruction, shown large in the command's place while there is no command.
    ///   - model: the bars. The app writes to it; the panel never copies it.
    ///   - rate: compressions per minute, or nil when there is none to show.
    ///   - rateInRange: false turns the rate to the accent.
    ///   - elapsedSeconds: time since the session started.
    ///   - onAskChanged: true when "Hold to ask" is pressed, false when it is let go.
    ///   - onFindAED: "Find AED" was pressed.
    ///   - onShowWorking: "Show working" was pressed.
    ///   - onHandOver: when set, a hold-to-confirm "Hand over" takes the place of "Hold to ask".
    ///     The app sets it once pushing has stopped, which is when a crew takes over.
    ///   - onCheckChest: when set and there is no rate yet, "Check chest" stands where the rate will be.
    ///     The app sets it only before the first push: once pushing has started the check has nothing to add.
    public init(command: String?,
                tone: CommandTone = .fix,
                startPrompt: String? = nil,
                model: BarFieldModel,
                rate: Double?,
                rateInRange: Bool,
                elapsedSeconds: Double,
                onAskChanged: @escaping (Bool) -> Void,
                onFindAED: @escaping () -> Void,
                onShowWorking: @escaping () -> Void,
                onHandOver: (() -> Void)? = nil,
                onCheckChest: (() -> Void)? = nil) {
        self.command = command
        self.tone = tone
        self.startPrompt = startPrompt
        self.model = model
        self.rate = rate
        self.rateInRange = rateInRange
        self.elapsedSeconds = elapsedSeconds
        self.onAskChanged = onAskChanged
        self.onFindAED = onFindAED
        self.onShowWorking = onShowWorking
        self.onHandOver = onHandOver
        self.onCheckChest = onCheckChest
    }

    /// The four rows, top to bottom, on the dark ground.
    public var body: some View {
        let metrics = Theme.metrics
        VStack(alignment: .leading, spacing: 0) {
            CommandSlot(command: command, tone: tone, startPrompt: startPrompt)
            BarField(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, metrics.rowGap * unit)
            RateRow(rate: rate, rateInRange: rateInRange, elapsedSeconds: elapsedSeconds, model: model,
                    onCheckChest: onCheckChest)
            Rectangle()
                .fill(Theme.Palette.quietOnGround.color.opacity(metrics.ruleOpacity))
                .frame(height: metrics.ruleWidth * unit)
            controls
        }
        .padding(.horizontal, metrics.panelPadding * unit)
        .padding(.top, metrics.topPadding * unit)
        .background(Theme.Palette.ground.color)
        .environment(\.plumbSurface, .ground)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            if let onHandOver {
                HoldToConfirm("Hand over", onConfirmed: onHandOver)
            } else {
                HoldToConfirm("Hold to ask",
                              holdSeconds: Theme.metrics.askFillSeconds,
                              onBegan: { onAskChanged(true) },
                              onEnded: { onAskChanged(false) })
            }
            Spacer(minLength: 0)
            PlainControl(title: "Find AED", tone: .aed, action: onFindAED)
            Spacer(minLength: 0)
            PlainControl(title: "Show working", tone: .quiet, action: onShowWorking)
        }
        .frame(height: Theme.metrics.controlHeight * unit)
    }
}
