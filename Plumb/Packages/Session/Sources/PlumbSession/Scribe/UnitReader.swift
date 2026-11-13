/// Reads the words after a number to find out what kind of quantity it is.
enum UnitReader {
    /// The kind of quantity the tokens at `start` name, and the index just past them.
    static func unit(at start: Int, in tokens: [SentenceToken]) -> (NumberClaim.Kind, Int)? {
        var index = start
        if let mark = tokens.mark(index), UnitWords.hyphens.contains(mark), tokens.word(index + 1) != nil {
            index += 1
        }
        if tokens.mark(index) == UnitWords.percentSign { return (.percent, index + 1) }
        if let end = rateEnd(at: index, in: tokens) { return (.rate, end) }
        guard let word = tokens.word(index) else { return nil }

        if UnitWords.percent.contains(word) { return (.percent, index + 1) }
        if word == UnitWords.percentPair.first, tokens.word(index + 1) == UnitWords.percentPair.second {
            return (.percent, index + 2)
        }
        if UnitWords.centimetres.contains(word) { return (.depthCM, index + 1) }
        if UnitWords.millimetres.contains(word) { return (.depthMM, index + 1) }
        if UnitWords.seconds.contains(word) { return (.seconds, index + 1) }
        if UnitWords.minutes.contains(word) { return (.minutes, index + 1) }
        // "110 compressions per minute": one plain noun may sit between the number and the rate words.
        if !UnitWords.rangeWords.contains(word), NumberWords.values[word] == nil,
           let end = rateEnd(at: index + 1, in: tokens) {
            return (.rate, end)
        }
        return nil
    }

    /// The index just past "per minute", "a minute", "/min" or "bpm" starting at `index`.
    private static func rateEnd(at index: Int, in tokens: [SentenceToken]) -> Int? {
        if let word = tokens.word(index), UnitWords.rateWhole.contains(word) { return index + 1 }
        let startsRate = tokens.mark(index) == UnitWords.rateSlash
            || tokens.word(index).map(UnitWords.ratePer.contains) == true
        guard startsRate, let unit = tokens.word(index + 1), UnitWords.minutes.contains(unit) else { return nil }
        return index + 2
    }

    /// What a number with no unit counts, when one of the next few words says so.
    static func countNoun(after index: Int, in tokens: [SentenceToken], reach: Int) -> CountNoun? {
        guard reach > 0 else { return nil }
        for step in 1...reach {
            // Anything that is not a plain word ends the search: a comma or another number
            // starts a new thought, and the noun after it belongs to that one.
            guard let word = tokens.word(index + step), NumberWords.values[word] == nil else { return nil }
            if word.hasPrefix(UnitWords.pauseNoun) { return .pauses }
            if word.hasPrefix(UnitWords.compressionNoun) { return .compressions }
        }
        return nil
    }
}
