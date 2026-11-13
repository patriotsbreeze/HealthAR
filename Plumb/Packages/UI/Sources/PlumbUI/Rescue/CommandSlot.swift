import SwiftUI

/// What a command asks of the rescuer, which decides its colour and how long it stays.
public enum CommandTone: Sendable, Equatable {
    /// Something to fix now. Set in the accent and shown for as long as the app passes it.
    case fix
    /// Things are right. Set in the mark colour, shown for a couple of seconds, then gone.
    case affirm
}

/// The fixed-height slot at the top of the panel. It holds one command, or the first instruction, or nothing.
struct CommandSlot: View {
    let command: String?
    let tone: CommandTone
    let startPrompt: String?

    /// The affirming command that has already had its time on screen.
    @State private var spent: String?

    @Environment(\.plumbUnit) private var unit

    var body: some View {
        ZStack(alignment: .leading) {
            if let shown {
                // The command is the only upper-case text in the app, whatever case it arrives in.
                Text(shown.uppercased())
                    .font(Theme.Face.command(unit: unit))
                    .foregroundStyle(tone == .fix ? Theme.Palette.accent.color : Theme.Palette.paper.color)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
                    .accessibilityAddTraits(.isHeader)
            } else if command == nil, let startPrompt {
                // Before the first push this line is the one thing that matters, so it is set as a headline.
                Text(startPrompt)
                    .font(Theme.Face.numeral(.figure, unit: unit))
                    .foregroundStyle(Theme.Palette.paper.color)
                    .lineLimit(Theme.metrics.wrapLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Theme.metrics.commandSlotHeight * unit)
        .animation(.linear(duration: Theme.metrics.fadeSeconds), value: shown)
        .task(id: Showing(command: command, tone: tone)) {
            spent = nil
            guard tone == .affirm, let command else { return }
            try? await Task.sleep(for: .seconds(Theme.metrics.affirmSeconds))
            if !Task.isCancelled { spent = command }
        }
    }

    private var shown: String? {
        Self.visible(command: command, tone: tone, spent: spent)
    }

    /// The command that should be on screen: the app's command, unless it is an affirmation that has had its time.
    static func visible(command: String?, tone: CommandTone, spent: String?) -> String? {
        tone == .affirm && command == spent ? nil : command
    }

    /// What restarts the affirming command's clock: a new command, or the same words in a new tone.
    private struct Showing: Equatable {
        let command: String?
        let tone: CommandTone
    }
}
