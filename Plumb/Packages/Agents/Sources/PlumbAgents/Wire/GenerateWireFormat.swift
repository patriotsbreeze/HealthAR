import Foundation

// ─────────────────────────────────────────────────────────────────────────────────────────────
// WIRE FORMAT: plain HTTPS calls.
// Every URL, header and JSON field name used by GeminiClient is in this file and nowhere else.
// If the real server disagrees with anything, this is the only file to change.
// Read on 2026-11-11 from the official pages listed in the package report.
// ─────────────────────────────────────────────────────────────────────────────────────────────

/// Which request and response shape the HTTPS calls use.
public enum GenerateDialect: String, Sendable, Equatable {
    /// `POST /v1beta/interactions`, the shape the current documentation shows for every example.
    case interactions
    /// `POST /v1beta/models/{model}:generateContent`, the older shape, documented as still supported.
    /// Switch to it if the interactions endpoint misbehaves.
    case generateContent
}

/// One request to a model, before it is given a wire shape.
struct GenerateCall: Sendable {
    var model: String
    var system: String
    var parts: [PromptPart]
    var schema: JSONValue?
    var thinking: String?
}

enum GenerateWireFormat {
    static let jsonMime = "application/json"
    static let jpegMime = "image/jpeg"
    static let revisionHeader = "Api-Revision"

    /// Builds the HTTPS request. The key travels in a header, never in the URL.
    static func request(_ call: GenerateCall, apiKey: String, config: AgentsConfig,
                        timeout: Duration) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = WireFormat.host
        let body: JSONValue
        switch config.restDialect {
        case .interactions:
            components.path = "/v1beta/interactions"
            body = interactionsBody(call)
        case .generateContent:
            components.path = "/v1beta/models/\(call.model):generateContent"
            body = generateContentBody(call)
        }
        guard let url = components.url else { throw GeminiError.unbuildable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout.inSeconds
        request.setValue(apiKey, forHTTPHeaderField: WireFormat.keyHeader)
        request.setValue(jsonMime, forHTTPHeaderField: "Content-Type")
        if config.restDialect == .interactions, let revision = config.apiRevision {
            request.setValue(revision, forHTTPHeaderField: revisionHeader)
        }
        request.httpBody = try body.encoded()
        return request
    }

    /// Pulls the model's text out of a successful response.
    static func text(in body: Data, dialect: GenerateDialect) throws -> String {
        guard let root = try? JSONValue(parsing: body) else { throw GeminiError.unreadable }
        let pieces: [String]
        let whyEmpty: String
        switch dialect {
        case .interactions:
            // steps[] of type "model_output" each hold content[] of type "text".
            let outputs = (root["steps"]?.array ?? []).filter { $0["type"]?.string == "model_output" }
            pieces = outputs.flatMap { $0["content"]?.array ?? [] }
                .filter { $0["type"]?.string == "text" }
                .compactMap { $0["text"]?.string }
            whyEmpty = "status \(root["status"]?.string ?? "unknown")"
        case .generateContent:
            // candidates[0].content.parts[] hold text; parts flagged as thoughts are not the answer.
            let candidate = root["candidates"]?.array?.first
            pieces = (candidate?["content"]?["parts"]?.array ?? [])
                .filter { $0["thought"]?.bool != true }
                .compactMap { $0["text"]?.string }
            let reason = root["promptFeedback"]?["blockReason"]?.string ?? candidate?["finishReason"]?.string
            whyEmpty = "reason \(reason ?? "unknown")"
        }
        let text = pieces.joined()
        guard !text.isEmpty else { throw GeminiError.noText(detail: Scrubber.label(whyEmpty)) }
        return text
    }

    /// The human-readable message inside an error response, when the body has the usual
    /// `{"error": {"message": …}}` shape. The interactions endpoint was seen to wrap that object
    /// in a one-item list, so both forms are read.
    static func errorMessage(in body: Data) -> String? {
        guard let root = try? JSONValue(parsing: body) else { return nil }
        return (root.array?.first ?? root)["error"]?["message"]?.string
    }

    // MARK: - Request bodies

    private static func interactionsBody(_ call: GenerateCall) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(call.model),
            "system_instruction": .string(call.system),
            "input": .array(call.parts.map { part in
                switch part {
                case .text(let text):
                    return ["type": "text", "text": .string(text)]
                case .jpeg(let data):
                    return ["type": "image", "data": .string(data.base64EncodedString()), "mime_type": .string(jpegMime)]
                }
            }),
            // Interactions are kept on the server unless this is false. Nothing here needs them kept.
            "store": false,
        ]
        if let schema = call.schema {
            body["response_format"] = ["type": "text", "mime_type": .string(jsonMime), "schema": schema]
        }
        if let thinking = call.thinking {
            body["generation_config"] = ["thinking_level": .string(thinking)]
        }
        return .object(body)
    }

    private static func generateContentBody(_ call: GenerateCall) -> JSONValue {
        var generation: [String: JSONValue] = [:]
        if let schema = call.schema {
            generation["responseMimeType"] = .string(jsonMime)
            generation["responseJsonSchema"] = schema
        }
        if let thinking = call.thinking {
            generation["thinkingConfig"] = ["thinkingLevel": .string(thinking)]
        }
        var body: [String: JSONValue] = [
            "systemInstruction": ["parts": [["text": .string(call.system)]]],
            "contents": [[
                "role": "user",
                "parts": .array(call.parts.map { part in
                    switch part {
                    case .text(let text):
                        return ["text": .string(text)]
                    case .jpeg(let data):
                        return ["inlineData": ["mimeType": .string(jpegMime), "data": .string(data.base64EncodedString())]]
                    }
                }),
            ]],
        ]
        if !generation.isEmpty {
            body["generationConfig"] = .object(generation)
        }
        return .object(body)
    }
}
