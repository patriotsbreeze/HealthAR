import Foundation
import Synchronization

/// All HTTP goes through this, so tests never touch the network.
public typealias HTTPClient = @Sendable (URLRequest) async throws -> (Data, URLResponse)

private let sharedSession = URLSession(configuration: .ephemeral)

public let liveHTTPClient: HTTPClient = { try await sharedSession.data(for: $0) }

/// One stateless generateContent call. Every failure is nil, so no error text can carry the key.
enum GeminiREST {
    static func generateText(
        model: String,
        body: JSONValue,
        apiKey: APIKey,
        http: HTTPClient,
        timeout: TimeInterval
    ) async -> String? {
        await generate(model: model, body: body, apiKey: apiKey, http: http, timeout: timeout)?.text
    }

    /// The reply's text, with the thought summaries kept apart, for a caller that asked for them.
    static func generate(
        model: String,
        body: JSONValue,
        apiKey: APIKey,
        http: HTTPClient,
        timeout: TimeInterval
    ) async -> Reply? {
        await generateWithStatus(model: model, body: body, apiKey: apiKey, http: http, timeout: timeout).reply
    }

    /// The same call, with the HTTP status when there was one, so a caller can tell a rate limit from
    /// an overload. The status never carries the key.
    static func generateWithStatus(
        model: String,
        body: JSONValue,
        apiKey: APIKey,
        http: HTTPClient,
        timeout: TimeInterval
    ) async -> (reply: Reply?, status: Int?, error: String?) {
        guard !apiKey.isEmpty,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"),
              let payload = try? body.encoded()
        else { return (nil, nil, nil) }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey.value, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = payload

        guard let (data, response) = try? await http(request) else { return (nil, nil, nil) }
        let status = (response as? HTTPURLResponse)?.statusCode
        // Google's error message, for logs. The key goes in a header, so it's never in here.
        guard status == 200 else { return (nil, status, String(decoding: data.prefix(300), as: UTF8.self)) }
        return (reply(from: data), status, nil)
    }

    struct Reply: Sendable, Equatable {
        var text: String
        var thoughts: String
    }

    /// Joins the text parts of the first candidate, leaving out thought summaries.
    static func responseText(from data: Data) -> String? { reply(from: data)?.text }

    /// The answer and the thought summaries, each joined. Nil when there's no answer.
    static func reply(from data: Data) -> Reply? {
        struct Envelope: Decodable {
            struct Candidate: Decodable { let content: Content? }
            struct Content: Decodable { let parts: [Part]? }
            struct Part: Decodable {
                let text: String?
                let thought: Bool?
            }
            let candidates: [Candidate]?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let parts = envelope.candidates?.first?.content?.parts
        else { return nil }
        let text = parts.filter { $0.thought != true }.compactMap(\.text).joined()
        let thoughts = parts.filter { $0.thought == true }.compactMap(\.text).joined(separator: "\n")
        return text.isEmpty ? nil : Reply(text: text, thoughts: thoughts)
    }
}

/// Returns nil at the deadline, even if `operation` ignores cancellation. URLRequest's timeout
/// alone isn't enough, since it restarts whenever data arrives.
func withHardTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    _ operation: @escaping @Sendable () async -> T?
) async -> T? {
    await withCheckedContinuation { continuation in
        let once = ResumeOnce(continuation)
        let work = Task {
            once.resume(await operation())
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            work.cancel()
            once.resume(nil)
        }
    }
}

private final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T?, Never>?>

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ value: T?) {
        continuation.withLock {
            $0?.resume(returning: value)
            $0 = nil
        }
    }
}
