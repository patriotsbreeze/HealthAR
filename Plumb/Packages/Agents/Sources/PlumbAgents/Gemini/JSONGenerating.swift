import Foundation

/// One piece of what is sent to a model.
public enum PromptPart: Sendable, Equatable {
    /// Plain text.
    case text(String)
    /// A JPEG image, as its file bytes.
    case jpeg(Data)
}

/// Anything that can turn a prompt into a model's JSON answer. The scribe and the scene finder talk
/// to this, so tests can stand in for the network.
public protocol JSONGenerating: Sendable {
    /// Asks a model for JSON and returns the JSON text as bytes.
    ///
    /// - Parameters:
    ///   - model: the model id.
    ///   - system: the standing instruction for the model.
    ///   - parts: the text and images of the request, in order.
    ///   - schema: a JSON Schema the answer must follow, or nil to ask for JSON in the prompt alone.
    ///   - thinking: the model's thinking level, or nil for its default.
    ///   - timeout: the whole budget for the call, retries included.
    func generateJSON(model: String, system: String, parts: [PromptPart], schema: JSONValue?,
                      thinking: String?, timeout: Duration) async throws -> Data
}

public extension JSONGenerating {
    /// Asks a model for JSON at its default thinking level.
    func generateJSON(model: String, system: String, parts: [PromptPart], schema: JSONValue?,
                      timeout: Duration) async throws -> Data {
        try await generateJSON(model: model, system: system, parts: parts, schema: schema,
                               thinking: nil, timeout: timeout)
    }
}
