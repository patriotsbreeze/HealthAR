/// One piece of a sentence, as the checker reads it.
struct SentenceToken: Equatable {
    enum Kind: Equatable {
        /// Letters, folded to plain lower case so "Décès" and "DECES" read the same.
        case word(String)
        /// A number written in digits, with how many digits follow its decimal point.
        case number(Double, decimals: Int)
        /// A time of day such as 14:02 or 14:02:31.
        case clock(hour: Int, minute: Int, second: Int?)
        /// A number-like character that is not a plain 0 to 9, such as ½ or ٣.
        case oddDigit
        /// Any other visible character.
        case mark(Character)
    }

    var kind: Kind
    /// The characters as they appear in the sentence.
    var written: String
}

extension Character {
    /// True for the ten ASCII digits only. Other scripts' digits and digits carrying combining
    /// marks are not read as numbers, because the checker could not be sure of their value.
    var isPlainDigit: Bool {
        isASCII && isWholeNumber
    }
}

extension Array where Element == SentenceToken {
    /// The folded word at `index`, or nil when there is no word there.
    func word(_ index: Int) -> String? {
        guard indices.contains(index), case .word(let word) = self[index].kind else { return nil }
        return word
    }

    /// The mark at `index`, or nil when there is no mark there.
    func mark(_ index: Int) -> Character? {
        guard indices.contains(index), case .mark(let mark) = self[index].kind else { return nil }
        return mark
    }

    /// True when a number written in digits sits at `index`.
    func isNumber(_ index: Int) -> Bool {
        guard indices.contains(index), case .number = self[index].kind else { return false }
        return true
    }
}
