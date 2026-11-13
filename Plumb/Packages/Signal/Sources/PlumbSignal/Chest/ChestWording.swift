import Foundation

// Every word the chest check shows, fixed here so nothing downstream can rephrase them.
// They describe what the sensor saw on the chest, never the person: a chest that moves is not a person
// who is all right, and a still chest is reported as a measurement, not a diagnosis.

public extension ChestReading.State {
    /// What the check reports, in plain words.
    var words: String {
        switch self {
        case .unmeasured: "Looking for the chest"
        case .settling: "Watching the chest"
        case .movementSeen: "Chest movement seen"
        // Whole seconds counted so far, so the count never runs ahead. The space before "s" does not break.
        case .noMovementSeen(let seconds): "No chest movement seen for \(Int(max(0, seconds)))\u{00A0}s"
        }
    }

    /// The line the new record keeps when pushing starts from the check: what the sensor last saw, as a
    /// measurement taken before CPR began. Nil when the check had not yet seen enough to say either way.
    var noteBeforeCPR: String? {
        switch self {
        case .movementSeen, .noMovementSeen: "\(words) before CPR."
        case .unmeasured, .settling: nil
        }
    }
}

public extension ChestReading {
    /// The one command the check ever gives.
    static let startPushingWords = "Start pushing"

    /// What to do when there is nothing to measure.
    static let tapTheChestWords = "Tap the chest on the picture"

    /// The line the new record keeps, ahead of `State.noteBeforeCPR`, when pushing starts after the check
    /// prompted it: why "Start pushing" was shown, as the still stretch that set it off, `stillForS` seconds
    /// long. What the check saw last may have changed since, because the prompt stays once given, so this
    /// is the only place the reason survives. Nil when the check had not prompted.
    func promptNoteBeforeCPR(stillForS: Double) -> String? {
        guard startPushing else { return nil }
        let still = State.noMovementSeen(forSeconds: stillForS).words
        return "\(Self.startPushingWords) prompted after \(still.prefix(1).lowercased() + still.dropFirst())."
    }

    /// The status, in plain words.
    var statusText: String {
        state.words
    }

    /// "Start pushing" once the prompt has fired, and from then on until a person resets the check. Nil before.
    var commandText: String? {
        startPushing ? Self.startPushingWords : nil
    }

    /// One small line of context: how to give the check something to measure, or, once the command has taken
    /// the status's place, the status itself. Nil when the status alone says it.
    var contextText: String? {
        if state == .unmeasured { return Self.tapTheChestWords }
        return startPushing ? statusText : nil
    }
}
