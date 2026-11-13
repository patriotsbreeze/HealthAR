import Foundation

/// Holds the key so that printing, dumping, or interpolating anything that contains it shows nothing.
public struct APIKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let value: String

    public init(_ value: String) {
        self.value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEmpty: Bool { value.isEmpty }

    public var description: String { "[redacted]" }
    public var debugDescription: String { "[redacted]" }
    public var customMirror: Mirror { Mirror(self, children: []) }

    func scrubbed(_ text: String) -> String {
        isEmpty ? text : text.replacingOccurrences(of: value, with: "[redacted]")
    }
}
