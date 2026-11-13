import Foundation

/// Models often wrap JSON in a Markdown code fence even when asked for bare JSON.
enum FencedJSON {
    /// The text inside the first code fence, or the whole text when there is no fence.
    static func unwrap(_ text: String) -> String {
        guard let opening = text.range(of: "```") else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var inside = text[opening.upperBound...]
        // The rest of the opening line is a language tag such as "json", not content.
        if let lineEnd = inside.firstIndex(where: \.isNewline) {
            inside = inside[inside.index(after: lineEnd)...]
        }
        if let closing = inside.range(of: "```") {
            inside = inside[..<closing.lowerBound]
        }
        return inside.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
