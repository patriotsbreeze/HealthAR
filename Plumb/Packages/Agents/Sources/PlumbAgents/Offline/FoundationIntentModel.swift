#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// The intents as the on-device model may produce them.
///
/// Guided generation holds the model's output to exactly these cases, so the most it can do is name a
/// topic. It has no way to write words that reach the person.
@available(iOS 26.0, macOS 26.0, *)
@Generable(description: "The one topic a spoken question about practice chest compressions asks about.")
enum GeneratedIntent {
    case overall
    case rate
    case depth
    case pauses
    case count
    case unknown

    var askIntent: AskIntent {
        switch self {
        case .overall: .overall
        case .rate: .rate
        case .depth: .depth
        case .pauses: .pauses
        case .count: .count
        case .unknown: .unknown
        }
    }
}

/// The system's on-device language model, used only to sort a question into an intent.
@available(iOS 26.0, macOS 26.0, *)
enum FoundationIntentModel {
    /// Nil when the model can be asked now, otherwise why not, in plain words.
    static func unavailableReason() -> String? {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "This phone cannot run the on-device model."
            case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off."
            case .modelNotReady: return "The on-device model is not ready yet."
            @unknown default: return "The on-device model is not available."
            }
        }
        guard model.supportsLocale() else { return "The on-device model does not support this language." }
        return nil
    }

    /// Loads the model ahead of the first question.
    static func prewarm() {
        LanguageModelSession(instructions: IntentPrompt.instructions).prewarm()
    }

    /// The intent of one question. A fresh session each time, so no question colours the next.
    static func ask(_ question: String) async throws -> AskIntent {
        let session = LanguageModelSession(instructions: IntentPrompt.instructions)
        let response = try await session.respond(to: "Question: \(question)", generating: GeneratedIntent.self,
                                                 options: GenerationOptions(sampling: .greedy))
        return response.content.askIntent
    }
}
#endif
