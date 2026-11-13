/// A subject the record holds nothing about, so no sentence may touch it.
enum BannedTopic: String, Sendable, CaseIterable {
    case diagnosis = "a diagnosis"
    case outcome = "the outcome"
    case cause = "the cause"
    case signsOfLife = "signs of life"
    case medicines = "medicines"
    case accuracy = "how accurate the measurement is"
    case blame = "who is to blame"
}

/// One banned word stem, or a phrase of stems that must appear as neighbouring words.
struct BannedIdea: Sendable, Equatable {
    var stems: [String]
    var topic: BannedTopic
}

/// The fixed list of ideas a model-written handoff sentence may never contain.
enum BannedIdeas {
    static let all: [BannedIdea] = [
        BannedIdea(stems: ["diagnos"], topic: .diagnosis),
        BannedIdea(stems: ["surviv"], topic: .outcome),
        BannedIdea(stems: ["prognos"], topic: .outcome),
        BannedIdea(stems: ["cause", "of"], topic: .cause),
        BannedIdea(stems: ["heart", "attack"], topic: .cause),
        BannedIdea(stems: ["cardiac", "arrest", "was"], topic: .cause),
        BannedIdea(stems: ["dead"], topic: .outcome),
        BannedIdea(stems: ["death"], topic: .outcome),
        BannedIdea(stems: ["died"], topic: .outcome),
        BannedIdea(stems: ["alive"], topic: .outcome),
        BannedIdea(stems: ["pulse"], topic: .signsOfLife),
        BannedIdea(stems: ["breathing", "normally"], topic: .signsOfLife),
        BannedIdea(stems: ["drug"], topic: .medicines),
        BannedIdea(stems: ["dose"], topic: .medicines),
        BannedIdea(stems: ["mg"], topic: .medicines),
        BannedIdea(stems: ["medicat"], topic: .medicines),
        BannedIdea(stems: ["recover"], topic: .outcome),
        BannedIdea(stems: ["saved"], topic: .outcome),
        BannedIdea(stems: ["clinically"], topic: .accuracy),
        BannedIdea(stems: ["accurate"], topic: .accuracy),
        BannedIdea(stems: ["validated"], topic: .accuracy),
        BannedIdea(stems: ["should", "have"], topic: .blame),
        BannedIdea(stems: ["failed", "to"], topic: .blame),
        BannedIdea(stems: ["blame"], topic: .blame),
    ]

    /// Beginnings that turn a stem into its opposite or a close relative without changing the
    /// subject: "inaccurate", "unvalidated", "misdiagnosed", "overdose".
    static let prefixes = ["in", "un", "mis", "non", "over", "under"]

    /// What is wrong, as one plain sentence, or nil when the sentence touches no banned idea.
    static func problem(in words: [String?], config: SessionConfig) -> String? {
        for idea in all {
            let run = WordSequence.firstRun(in: words, fitting: idea.stems) { word, stem in
                fits(word, stem: stem, config: config)
            }
            if let run {
                return "It uses \"\(run.joined(separator: " "))\", and the record says nothing about \(idea.topic.rawValue)."
            }
        }
        return nil
    }

    /// A word fits a stem when it starts with it, with or without one of the prefixes in front.
    /// Very short stems must be the whole word.
    static func fits(_ word: String, stem: String, config: SessionConfig) -> Bool {
        if stem.count <= config.wholeWordStemLength { return word == stem }
        return word.hasPrefix(stem) || prefixes.contains { word.hasPrefix($0 + stem) }
    }
}
