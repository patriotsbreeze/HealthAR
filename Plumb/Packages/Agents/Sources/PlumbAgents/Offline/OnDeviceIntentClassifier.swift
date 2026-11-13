import Foundation

/// Reads a question's intent with the language model on this phone, and falls back to the keyword
/// rules whenever the model cannot help in time.
///
/// The model is held by guided generation to the closed set of intents, so it can only name a topic;
/// the answer is always a fixed template. It falls back, and says why, when the model is missing or
/// switched off, when it fails or refuses, and when it has not answered within the time limit. A
/// person holding a button gets an answer either way.
public struct OnDeviceIntentClassifier: IntentClassifying {
    /// Longest the model may take before the keyword rules decide instead.
    public let timeLimit: Duration
    private let model: IntentModel
    private let keywords = KeywordIntentClassifier()

    /// - Parameter timeLimit: how long the model may take. About a second and a half keeps the
    ///   answer quick enough to follow a question.
    public init(timeLimit: Duration = .milliseconds(1500)) {
        self.init(timeLimit: timeLimit, model: .onDevice)
    }

    init(timeLimit: Duration, model: IntentModel) {
        self.timeLimit = timeLimit
        self.model = model
    }

    /// Loads the model ahead of the first question, when the model is there at all.
    public func prepare() {
        guard model.unavailableReason() == nil else { return }
        model.prepare()
    }

    /// The model's reading of `question`, or the keyword rules' reading with the reason the model
    /// was not used.
    public func classify(_ question: String) async -> IntentReading {
        if let reason = model.unavailableReason() {
            return fallback(question, reason: reason)
        }
        let ask = model.ask
        switch await runTimed(within: timeLimit, { try await ask(question) }) {
        case .finished(let intent):
            return IntentReading(intent: intent, classifiedBy: .model)
        case .failed:
            return fallback(question, reason: "The on-device model could not read the question.")
        case .overran:
            return fallback(question, reason: "The on-device model took longer than \(timeLimit.inSeconds.oneDecimal) seconds.")
        }
    }

    private func fallback(_ question: String, reason: String) -> IntentReading {
        IntentReading(intent: keywords.intent(for: question), classifiedBy: .keywords, fallbackReason: reason)
    }
}
