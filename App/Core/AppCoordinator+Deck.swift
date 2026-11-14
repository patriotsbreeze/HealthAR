import Foundation
import RescueCore

/// What the command deck reads. `instruction` and `stepDetail` stay as they are, since tests and the
/// sheets pin them. These only choose which of the same phrases leads.
extension AppCoordinator {
    /// The deck's big line: the first of the step's own lines that tells someone to do something, or
    /// the one the step's camera marks belong to. A leading "Possible X." line says what it may be,
    /// not what to do, and the why row under the command already says it with "Not a diagnosis."
    /// after it.
    var deckCommand: String {
        deckCommandPhraseID.flatMap(engine.bundle.text(forPhrase:)) ?? instruction
    }

    /// The step's other lines, in order. A "Possible X." line skipped for the command stays here
    /// unless the why row is on screen to say it.
    var deckDetail: String? {
        guard let definition, let command = deckCommandPhraseID else { return stepDetail }
        let skipped = flowExplanation == nil ? [] : leadingPossibleIDs
        let lines = definition.entryPhrases
            .filter { $0 != command && !skipped.contains($0) }
            .compactMap(engine.bundle.text(forPhrase:))
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    var stepProgress: StepProgress? {
        StepProgressBuilder.build(engine: engine, entries: log.entries, stateID: state.stateID)
    }

    /// The step's cues name the body part and the things to grab, so a word in the command lights up
    /// with its mark on the camera.
    var commandTerms: CommandEmphasis.Terms {
        CommandEmphasis.terms(target: overlayTarget, bodies: cues.compactMap(\.body), materials: cues.compactMap(\.material))
    }

    /// One sentence that only names the condition, like "Possible heart attack." A line that goes on
    /// to say what to do is a command, and stays one.
    nonisolated static func isPossibleLine(_ text: String) -> Bool {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("Possible "), line.hasSuffix(".") else { return false }
        return !line.dropLast().contains { ".!?".contains($0) }
    }

    private var leadingPossibleIDs: [String] {
        let phrases = definition?.entryPhrases ?? []
        return Array(phrases.prefix { engine.bundle.text(forPhrase: $0).map(Self.isPossibleLine) ?? false })
    }

    /// The call line. Nothing a step points at on the camera goes ahead of it.
    nonisolated static let callPhraseID = "call_911"
    /// Said on the way, never the step's instruction: the call happens in the background.
    nonisolated static let announcementPhraseIDs = ProtocolEngine.announcementPhrases

    /// The first line after any "Possible X." one, unless a cue on this step points at a later line:
    /// then that one leads, so the nouns said big are the ones the marks light up, as on limb_splint,
    /// whose towel and pillow callouts belong to its second line. Never ahead of the call line.
    private var deckCommandPhraseID: String? {
        guard let definition, !definition.entryPhrases.isEmpty else { return nil }
        let lines = Array(definition.entryPhrases.dropFirst(leadingPossibleIDs.count))
            .filter { !Self.announcementPhraseIDs.contains($0) }
        if let index = lines.firstIndex(where: { line in definition.cues.contains { $0.phrase == line } }),
           !lines[..<index].contains(Self.callPhraseID) {
            return lines[index]
        }
        return lines.first
    }
}
