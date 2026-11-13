import PlumbContracts

// Two-state wording in the style of defibrillator prompts: a short order, or a short confirmation.
// The words are fixed here so that nothing downstream can rephrase them.

public extension Cue {
    /// The words said out loud for this cue, in sentence case.
    var spokenText: String {
        switch self {
        case .pushNow: "Push now"
        case .pushHarder: "Push harder"
        case .faster: "Faster"
        case .slower: "Slower"
        case .good: "Good compressions"
        }
    }

    /// The words shown in the on-screen command slot for this cue, in upper case.
    var commandText: String {
        switch self {
        case .pushNow: "PUSH NOW"
        case .pushHarder: "PUSH HARDER"
        case .faster: "FASTER"
        case .slower: "SLOWER"
        case .good: "GOOD"
        }
    }
}
