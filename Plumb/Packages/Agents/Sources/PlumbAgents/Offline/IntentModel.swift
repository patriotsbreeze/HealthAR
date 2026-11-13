import Foundation

/// The language model behind `OnDeviceIntentClassifier`, as three plain functions so tests can stand
/// in for it.
struct IntentModel: Sendable {
    /// Nil when the model can be asked now, otherwise why not, in plain words.
    var unavailableReason: @Sendable () -> String?
    /// Asks the system to load the model ahead of the first question.
    var prepare: @Sendable () -> Void
    /// The intent of one question. Throws when the model fails or refuses.
    var ask: @Sendable (String) async throws -> AskIntent

    /// The system's on-device model where this build and this system have it.
    static var onDevice: IntentModel {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return IntentModel(unavailableReason: { FoundationIntentModel.unavailableReason() },
                               prepare: { FoundationIntentModel.prewarm() },
                               ask: { try await FoundationIntentModel.ask($0) })
        }
        return missing("The on-device model needs a newer system.")
        #else
        return missing("The on-device model is not part of this build.")
        #endif
    }

    /// A model that is never there, for builds and systems without one.
    static func missing(_ reason: String) -> IntentModel {
        IntentModel(unavailableReason: { reason }, prepare: {}, ask: { _ in throw Unavailable(reason: reason) })
    }

    /// Thrown when a model that is not there is asked anyway.
    struct Unavailable: Error {
        var reason: String
    }
}

/// What the on-device model is told. It sorts a question into one topic and never answers it.
enum IntentPrompt {
    static let instructions = """
    You sort one spoken question into exactly one topic. The question comes from a person practising \
    chest compressions on a training manikin. You never answer the question.
    rate: how fast, the speed, the pace, the beat, compressions per minute.
    depth: how deep, how hard, pushing hard enough or too softly.
    pauses: stopping, breaks, gaps, time with the hands off.
    count: how many compressions so far.
    overall: how it is going in general, or more than one of the topics above.
    unknown: anything else, including any question about a person's condition.
    """
}
