import Foundation

/// Reads a question's intent from its words alone, by fixed rules. Always available, instant, and the
/// same answer every time for the same words.
///
/// The rules, in order:
/// 1. A question that mentions a person's condition (breathing, pulse, survival and the like), names
///    the person ("he", "the patient") or asks how things will turn out ("will he make it") is
///    `unknown`, whatever else it asks.
/// 2. If it names exactly one of rate, depth, pauses or count, that is the intent. "How many" with a
///    unit ("a minute", "centimetres") asks for that measurement, not the count.
/// 3. If it names more than one, it is `overall`, which covers rate, depth and the pause together.
/// 4. If it names none but asks how it is going, it is `overall`. Otherwise it is `unknown`.
public struct KeywordIntentClassifier: IntentClassifying {
    /// Creates the classifier. It holds nothing.
    public init() {}

    /// The intent by the fixed rules, reported as decided by keywords.
    public func classify(_ question: String) async -> IntentReading {
        IntentReading(intent: intent(for: question), classifiedBy: .keywords)
    }

    /// The intent of `question` by the fixed rules.
    public func intent(for question: String) -> AskIntent {
        let words = Self.words(in: question)
        guard !words.isEmpty, !Self.mentionsCondition(words) else { return .unknown }

        var named = Set<AskIntent>()
        if Self.matches(words, IntentKeywords.rate) { named.insert(.rate) }
        if Self.matches(words, IntentKeywords.depth) { named.insert(.depth) }
        if Self.matches(words, IntentKeywords.pauses) { named.insert(.pauses) }
        if Self.matches(words, IntentKeywords.count) { named.insert(.count) }
        if named.contains(.count), Self.matches(words, IntentKeywords.units) {
            named.remove(.count)
        }

        if named.count == 1, let only = named.first { return only }
        if named.count > 1 { return .overall }
        return Self.matches(words, IntentKeywords.overall) ? .overall : .unknown
    }

    /// True when `question` mentions a person's condition, names the person or asks how things will turn
    /// out. Such a question is never answered from the measurements, whichever classifier reads it.
    public static func asksAboutCondition(_ question: String) -> Bool {
        mentionsCondition(words(in: question))
    }

    // MARK: - Words

    /// The question as plain lower-case words, with accents and apostrophes removed.
    static func words(in text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .filter { $0 != "'" && $0 != "\u{2019}" }
        return folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func mentionsCondition(_ words: [String]) -> Bool {
        words.contains { IntentKeywords.condition.contains($0) || IntentKeywords.person.contains($0) }
            || matches(words, IntentKeywords.outcome)
    }

    /// True when any of the phrases appears in `words` as a run of whole words.
    private static func matches(_ words: [String], _ phrases: [[String]]) -> Bool {
        phrases.contains { phrase in
            guard !phrase.isEmpty, phrase.count <= words.count else { return false }
            return (0...(words.count - phrase.count)).contains { start in
                words[start..<(start + phrase.count)].elementsEqual(phrase)
            }
        }
    }
}
