/// The words of a sentence in order, for finding words and phrases.
enum WordSequence {
    /// Every word in order. A number or clock time becomes a nil, because it breaks a phrase;
    /// punctuation is dropped, because "heart-attack" is still "heart attack".
    static func words(of tokens: [SentenceToken]) -> [String?] {
        var words: [String?] = []
        for token in tokens {
            switch token.kind {
            case .word(let word): words.append(word)
            case .number, .clock, .oddDigit: words.append(nil)
            case .mark: break
            }
        }
        return words
    }

    /// The first run of neighbouring words that fits `pattern` word for word, as found in the sentence.
    /// `fits` decides whether one sentence word fits one pattern word.
    static func firstRun(in words: [String?], fitting pattern: [String],
                         by fits: (_ word: String, _ patternWord: String) -> Bool) -> [String]? {
        guard !pattern.isEmpty, words.count >= pattern.count else { return nil }
        for start in 0...(words.count - pattern.count) {
            let run = words[start..<(start + pattern.count)].compactMap { $0 }
            if run.count == pattern.count, zip(run, pattern).allSatisfy(fits) { return run }
        }
        return nil
    }
}
