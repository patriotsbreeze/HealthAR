import Foundation

/// Splits a sentence into words, numbers, clock times and marks. Spaces are dropped.
enum SentenceScanner {
    static func tokens(in text: String) -> [SentenceToken] {
        let characters = Array(text)
        var tokens: [SentenceToken] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
            } else if character.isPlainDigit {
                let (token, end) = numeral(in: characters, from: index)
                tokens.append(token)
                index = end
            } else if character.isNumber {
                tokens.append(SentenceToken(kind: .oddDigit, written: String(character)))
                index += 1
            } else if character.isLetter {
                let end = characters[index...].firstIndex { !$0.isLetter || $0.isNumber } ?? characters.count
                let written = String(characters[index..<end])
                tokens.append(SentenceToken(kind: .word(folded(written)), written: written))
                index = end
            } else {
                tokens.append(SentenceToken(kind: .mark(character), written: String(character)))
                index += 1
            }
        }
        return tokens
    }

    /// Lower case with accents and other combining marks removed, so a word cannot dodge the
    /// word lists by decoration alone.
    private static func folded(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    /// Reads the clock time or number that starts at `start`, and the index just past it.
    private static func numeral(in characters: [Character], from start: Int) -> (SentenceToken, Int) {
        var end = digitsEnd(in: characters, from: start)
        if let clock = clock(in: characters, from: start, hourEnd: end) { return clock }

        var digits = String(characters[start..<end])
        // "1,200" is one number. Only groups of exactly three digits count, so a list such as
        // "3, 5" or a decimal comma is never swallowed.
        if end - start <= thousandsGroupLength {
            while let groupEnd = thousandsGroupEnd(in: characters, at: end) {
                digits += String(characters[(end + 1)..<groupEnd])
                end = groupEnd
            }
        }
        var decimals = 0
        if end + 1 < characters.count, characters[end] == ".", characters[end + 1].isPlainDigit {
            let fractionEnd = digitsEnd(in: characters, from: end + 1)
            decimals = fractionEnd - end - 1
            digits += "." + String(characters[(end + 1)..<fractionEnd])
            end = fractionEnd
        }
        // Digits with at most one point always parse; a value that is not a number backs nothing.
        let value = Double(digits) ?? .nan
        let token = SentenceToken(kind: .number(value, decimals: decimals), written: String(characters[start..<end]))
        return (token, end)
    }

    private static func clock(in characters: [Character], from start: Int,
                              hourEnd: Int) -> (SentenceToken, Int)? {
        guard hourEnd - start <= clockFieldLength,
              let minuteEnd = clockFieldEnd(in: characters, at: hourEnd) else { return nil }
        let secondEnd = clockFieldEnd(in: characters, at: minuteEnd)
        let end = secondEnd ?? minuteEnd
        let hour = Int(String(characters[start..<hourEnd])) ?? 0
        let minute = Int(String(characters[(hourEnd + 1)..<minuteEnd])) ?? 0
        let second = secondEnd.flatMap { Int(String(characters[(minuteEnd + 1)..<$0])) }
        let token = SentenceToken(kind: .clock(hour: hour, minute: minute, second: second),
                                  written: String(characters[start..<end]))
        return (token, end)
    }

    /// The index just past a ":dd" that starts at `colon`, when exactly two digits follow the colon.
    private static func clockFieldEnd(in characters: [Character], at colon: Int) -> Int? {
        let end = colon + 1 + clockFieldLength
        guard end <= characters.count, characters[colon] == ":",
              characters[(colon + 1)..<end].allSatisfy(\.isPlainDigit) else { return nil }
        if end < characters.count, characters[end].isPlainDigit { return nil }
        return end
    }

    /// The index just past a ",ddd" that starts at `comma`, when exactly three digits follow the comma.
    private static func thousandsGroupEnd(in characters: [Character], at comma: Int) -> Int? {
        let end = comma + 1 + thousandsGroupLength
        guard end <= characters.count, characters[comma] == ",",
              characters[(comma + 1)..<end].allSatisfy(\.isPlainDigit) else { return nil }
        if end < characters.count, characters[end].isPlainDigit { return nil }
        return end
    }

    private static func digitsEnd(in characters: [Character], from start: Int) -> Int {
        characters[start...].firstIndex { !$0.isPlainDigit } ?? characters.count
    }

    private static let clockFieldLength = 2
    private static let thousandsGroupLength = 3
}
