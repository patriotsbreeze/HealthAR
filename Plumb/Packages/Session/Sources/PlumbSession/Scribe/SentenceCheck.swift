import Foundation
import PlumbContracts

/// Runs every rule over one model-written sentence, against one session's log and stats.
struct SentenceCheck {
    /// The log, looked up by entry id.
    var entries: [Int: LogEntry]
    var stats: HandoffStats
    var timeZone: TimeZone
    var config: SessionConfig

    /// Why the sentence is refused, as one plain sentence, or nil when every rule holds.
    /// Rules run in a fixed order and the first one broken is the one reported.
    func refusal(of sentence: ScribeSentence, position: Int) -> String? {
        if sentence.text.allSatisfy(\.isWhitespace) {
            return "It is empty."
        }
        if position >= config.maxSentences {
            return "Only \(config.maxSentences) sentences are kept, and this is sentence \(position + 1)."
        }
        let tokens = SentenceScanner.tokens(in: sentence.text)
        let words = WordSequence.words(of: tokens)
        return SentenceShape.problem(in: sentence.text, tokens: tokens, config: config)
            ?? SelfReference.problem(in: words)
            ?? BannedIdeas.problem(in: words, config: config)
            ?? citeProblem(sentence.cites)
            ?? numberProblem(tokens, cites: sentence.cites)
    }

    private func citeProblem(_ cites: [Int]) -> String? {
        if cites.isEmpty {
            return "It cites no log entries."
        }
        if let missing = cites.first(where: { entries[$0] == nil }) {
            return "It cites entry \(missing), which is not in the log."
        }
        return nil
    }

    private func numberProblem(_ tokens: [SentenceToken], cites: [Int]) -> String? {
        let cited = cites.compactMap { entries[$0] }
        let values = BackingValues(stats: stats, cited: cited, config: config)
        let reading = NumberClaimReader.read(tokens, config: config)
        return NumberBacking.problem(in: reading, values: values, timeZone: timeZone, config: config)
    }
}
