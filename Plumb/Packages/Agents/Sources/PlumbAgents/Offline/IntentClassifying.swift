import Foundation

/// Reads a question and names its intent. It picks from `AskIntent` and does nothing else.
public protocol IntentClassifying: Sendable {
    /// Gets ready ahead of the first question, where that makes the first answer quicker.
    func prepare()
    /// The intent of one transcribed question. Never fails: when in doubt the intent is `unknown`.
    func classify(_ question: String) async -> IntentReading
}

public extension IntentClassifying {
    /// Most classifiers have nothing to load.
    func prepare() {}
}

/// What decided a question's intent.
public enum IntentSource: String, Sendable, Codable, Equatable {
    /// The language model on this phone, held to the closed set of intents.
    case model
    /// The fixed keyword rules.
    case keywords
}

/// One question's intent and what decided it.
public struct IntentReading: Sendable, Equatable {
    public var intent: AskIntent
    public var classifiedBy: IntentSource
    /// Why the keyword rules decided rather than the model, in plain words. Nil when the model
    /// decided, or when the keyword rules were the only classifier in use.
    public var fallbackReason: String?

    /// Creates a reading.
    public init(intent: AskIntent, classifiedBy: IntentSource, fallbackReason: String? = nil) {
        self.intent = intent
        self.classifiedBy = classifiedBy
        self.fallbackReason = fallbackReason
    }
}
