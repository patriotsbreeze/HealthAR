import Foundation
@testable import PlumbAgents

/// An in-memory model: plays back scripted answers and remembers what it was asked.
final class FakeGenerator: JSONGenerating, Sendable {
    struct Call: Sendable {
        var model: String
        var system: String
        var parts: [PromptPart]
        var schema: JSONValue?
        var thinking: String?
        var timeout: Duration

        /// All the text parts joined, which is the prompt as the model would read it.
        var text: String {
            parts.compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined(separator: "\n")
        }
    }

    enum Step: Sendable {
        case answer(String)
        case fail(any Error)
    }

    private let steps: Locked<[Step]>
    private let seen = Locked<[Call]>([])

    init(_ steps: [Step]) {
        self.steps = Locked(steps)
    }

    var calls: [Call] { seen.current }

    func generateJSON(model: String, system: String, parts: [PromptPart], schema: JSONValue?,
                      thinking: String?, timeout: Duration) async throws -> Data {
        seen.with { $0.append(Call(model: model, system: system, parts: parts, schema: schema,
                                   thinking: thinking, timeout: timeout)) }
        let step = steps.with { $0.isEmpty ? Step.fail(GeminiError.unreadable) : $0.removeFirst() }
        switch step {
        case .answer(let text): return Data(text.utf8)
        case .fail(let error): throw error
        }
    }
}
