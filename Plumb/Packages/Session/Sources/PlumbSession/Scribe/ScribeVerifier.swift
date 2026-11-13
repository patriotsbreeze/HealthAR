import Foundation
import PlumbContracts

/// The fixed checker for sentences a model writes about a session. No model is involved in the
/// check: the same sentences, log and stats always give the same verdicts.
public enum ScribeVerifier {
    /// One verdict per sentence, in order: accepted only when it cites real entries, every number is backed
    /// by them or by `stats`, and it is one short sentence with no banned idea and no narrator. Device time zone.
    public static func verify(_ sentences: [ScribeSentence], log: [LogEntry], stats: HandoffStats,
                              maxSentences: Int = SessionConfig.standard.maxSentences) -> [ScribeVerdict] {
        verify(sentences, log: log, stats: stats, maxSentences: maxSentences, timeZone: .current)
    }

    /// The same check, with clock times such as "14:02" read in `timeZone` instead of the device's.
    /// Pass the zone the handoff headline was written in.
    public static func verify(_ sentences: [ScribeSentence], log: [LogEntry], stats: HandoffStats,
                              maxSentences: Int = SessionConfig.standard.maxSentences,
                              timeZone: TimeZone) -> [ScribeVerdict] {
        var config = SessionConfig.standard
        config.maxSentences = maxSentences
        return verify(sentences, log: log, stats: stats, timeZone: timeZone, config: config)
    }

    static func verify(_ sentences: [ScribeSentence], log: [LogEntry], stats: HandoffStats,
                       timeZone: TimeZone, config: SessionConfig) -> [ScribeVerdict] {
        // Ids are unique in a real log. If a hand-made one repeats an id, the first entry wins.
        let entries = Dictionary(log.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let check = SentenceCheck(entries: entries, stats: stats, timeZone: timeZone, config: config)
        return sentences.enumerated().map { position, sentence in
            let reason = check.refusal(of: sentence, position: position)
            return ScribeVerdict(sentence: sentence, accepted: reason == nil, reason: reason)
        }
    }
}
