/// Finds sentences that speak as a person or as the model. A handoff states what was measured;
/// it has no narrator.
enum SelfReference {
    /// What is wrong, as one plain sentence, or nil when the sentence has no narrator.
    static func problem(in words: [String?]) -> String? {
        if let word = words.compactMap({ $0 }).first(where: firstPerson.contains) {
            return "It speaks in the first person (\"\(word)\")."
        }
        for phrase in modelPhrases {
            if let run = WordSequence.firstRun(in: words, fitting: phrase, by: ==) {
                return "It refers to the model itself (\"\(run.joined(separator: " "))\")."
            }
        }
        return nil
    }

    private static let firstPerson: Set<String> = [
        "i", "me", "my", "mine", "myself", "we", "us", "our", "ours", "ourselves",
    ]

    private static let modelPhrases: [[String]] = [
        ["ai"], ["llm"], ["chatbot"], ["language", "model"], ["as", "an", "assistant"], ["as", "a", "model"],
    ]
}
