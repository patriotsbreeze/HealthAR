import Foundation

/// Checks that a text is one plain, short sentence the other checks can actually read.
enum SentenceShape {
    /// What is wrong with the shape of the sentence, as one plain sentence, or nil when it is fine.
    static func problem(in text: String, tokens: [SentenceToken], config: SessionConfig) -> String? {
        if text.contains(where: \.isNewline) {
            return "It contains a line break."
        }
        if text.unicodeScalars.contains(where: isHidden) {
            return "It contains hidden or control characters."
        }
        if text.unicodeScalars.contains(where: isUnreadableLetter) {
            return "It uses letters outside the Latin alphabet, which the word checks cannot read."
        }
        if hasDigitInsideWord(text) {
            return "It mixes digits into a word, which the word checks cannot read."
        }
        if hasInnerSentenceEnd(text) {
            return "It is more than one sentence."
        }
        let words = wordCount(tokens)
        if words == 0 {
            return "It has no words."
        }
        if words > config.maxWords {
            return "It has \(words) words, and the limit is \(config.maxWords)."
        }
        return nil
    }

    /// Words, numbers and clock times each count as one word.
    static func wordCount(_ tokens: [SentenceToken]) -> Int {
        tokens.filter { token in
            if case .mark = token.kind { return false }
            return true
        }.count
    }

    /// Characters that take no space on screen could split a banned word in two without a reader seeing it.
    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .privateUse, .surrogate, .unassigned: return true
        default: return false
        }
    }

    /// Letters from other alphabets can look exactly like Latin ones and slip past the word lists.
    private static func isUnreadableLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return scalar.value > lastLatinLetter
        default:
            return false
        }
    }

    /// True when a digit follows a letter with no space, as in "d3ad". A digit before a unit
    /// ("5cm", "9s") is ordinary writing; a digit after a letter is a word in disguise.
    private static func hasDigitInsideWord(_ text: String) -> Bool {
        let characters = Array(text)
        return characters.indices.dropFirst().contains { index in
            characters[index].isNumber && characters[index - 1].isLetter
        }
    }

    /// True when a full stop, question mark or exclamation mark is followed by more words.
    private static func hasInnerSentenceEnd(_ text: String) -> Bool {
        let characters = Array(text)
        // Closing quotes and brackets may trail the final full stop without starting a new sentence.
        let lastOfBody = characters.lastIndex { character in
            !character.isWhitespace && !sentenceEnders.contains(character) && !closers.contains(character)
        }
        guard let lastOfBody else { return false }
        return characters[..<lastOfBody].indices.contains { index in
            sentenceEnders.contains(characters[index]) && !isDecimalPoint(characters, at: index)
        }
    }

    /// A full stop between two digits is part of a number, not the end of a sentence.
    private static func isDecimalPoint(_ characters: [Character], at index: Int) -> Bool {
        characters[index] == "." && index > 0 && index + 1 < characters.count
            && characters[index - 1].isPlainDigit && characters[index + 1].isPlainDigit
    }

    private static let sentenceEnders: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]"]
    /// End of the Latin Extended-B block: plain and accented Latin letters sit at or below it.
    private static let lastLatinLetter: UInt32 = 0x024F
}
