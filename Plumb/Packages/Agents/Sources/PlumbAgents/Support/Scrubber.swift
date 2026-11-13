import Foundation

/// Makes text that came from outside safe to show or log: no secret, no line breaks, no runaway length.
enum Scrubber {
    /// Removes the secret first and cuts second, so a cut can never leave part of the secret behind.
    static func clean(_ text: String, secret: String, limit: Int) -> String {
        let hidden = secret.isEmpty ? text : text.replacingOccurrences(of: secret, with: "[key]")
        return flatten(hidden, limit: limit)
    }

    /// One line, at most `limit` characters, with control characters dropped.
    static func flatten(_ text: String, limit: Int) -> String {
        let printable = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        }))
        let line = printable.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    /// A short name that arrived from a model, cut down to characters that cannot carry markup or
    /// instructions into a log line or a prompt.
    static func label(_ text: String, limit: Int = 40) -> String {
        let extras = CharacterSet(charactersIn: " _-.")
        let kept = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || extras.contains($0) }
        let trimmed = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(limit))
    }
}
