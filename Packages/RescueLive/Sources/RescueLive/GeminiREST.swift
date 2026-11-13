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
        guard !apiKey.isEmpty,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"),
              let payload = try? body.encoded()
        else { return nil }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey.value, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = payload

        guard let (data, response) = try? await http(request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return responseText(from: data)
    }

    /// Joins the text parts of the first candidate, leaving out thought summaries.
    static func responseText(from data: Data) -> String? {
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
        return text.isEmpty ? nil : text
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
