import Foundation
import PlumbContracts

/// The rules about a sentence's form that the scribe is told to follow, enforced here rather than
/// trusted. What a sentence says about the session is the number checker's business, not this one's.
enum ScribeGate {
    /// Why a sentence breaks the form rules, or nil when it keeps them.
    static func refusal(for sentence: ScribeSentence, offered: Set<Int>, maxWords: Int) -> String? {
        let words = sentence.text.split(whereSeparator: \.isWhitespace)
        if words.isEmpty {
            return "The sentence is empty."
        }
        if words.count > maxWords {
            return "Longer than \(maxWords) words."
        }
        if holdsMoreThanOneSentence(sentence.text) {
            return "More than one sentence."
        }
        if sentence.cites.isEmpty {
            return "Cites no log entry."
        }
        if !sentence.cites.allSatisfy(offered.contains) {
            return "Cites a log entry that was not provided."
        }
        return nil
    }

    /// True when a full stop, question mark or exclamation mark is followed by more text. A decimal
    /// point is not followed by a space, so "54.2 mm" does not count.
    private static func holdsMoreThanOneSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(where: \.isNewline) { return true }
        var previous: Character?
        for character in trimmed {
            if character.isWhitespace, let previous, ".!?".contains(previous) { return true }
            previous = character
        }
        return false
    }
}
