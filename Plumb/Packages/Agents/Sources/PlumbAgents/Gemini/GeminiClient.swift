import Foundation

/// Plain HTTPS calls to the model service: one prompt in, one JSON text out.
///
/// The key is held here and sent only as a request header. It never appears in a URL, a log line
/// or an error.
public struct GeminiClient: JSONGenerating {
    private let apiKey: String
    private let transport: any HTTPTransport
    private let config: AgentsConfig

    /// - Parameter apiKey: supplied by the app. Kept in memory only.
    public init(apiKey: String, transport: any HTTPTransport = URLSessionTransport(),
                config: AgentsConfig = AgentsConfig()) {
        self.apiKey = apiKey
        self.transport = transport
        self.config = config
    }

    /// Asks a model for JSON and returns the JSON text as bytes.
    ///
    /// Retries once after a transport failure or a 5xx, never after a 4xx. `timeout` covers the
    /// whole call, the retry included.
    public func generateJSON(model: String, system: String, parts: [PromptPart], schema: JSONValue?,
                             thinking: String?, timeout: Duration) async throws -> Data {
        let call = GenerateCall(model: model, system: system, parts: parts, schema: schema, thinking: thinking)
        guard let request = try? GenerateWireFormat.request(call, apiKey: apiKey, config: config, timeout: timeout) else {
            throw GeminiError.unbuildable
        }
        do {
            return try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { try await self.sendWithOneRetry(request) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw GeminiError.timedOut(seconds: timeout.inSeconds)
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw GeminiError.unreadable }
                return first
            }
        } catch let error as GeminiError {
            throw error
        } catch {
            // Only cancellation of the caller reaches here; every other failure is already a GeminiError.
            throw GeminiError.cancelled
        }
    }

    // MARK: - Private

    private func sendWithOneRetry(_ request: URLRequest) async throws -> Data {
        var failure = GeminiError.unreadable
        for attempt in 1...2 {
            if attempt == 2 {
                try await Task.sleep(for: config.retryPause)
            }
            let body: Data
            let response: HTTPURLResponse
            do {
                (body, response) = try await transport.send(request)
            } catch is CancellationError {
                throw GeminiError.cancelled
            } catch {
                failure = .transport(detail: clean(error.localizedDescription))
                continue
            }
            switch response.statusCode {
            case 200..<300:
                return Data(try GenerateWireFormat.text(in: body, dialect: config.restDialect).utf8)
            case 500..<600:
                failure = .http(status: response.statusCode, detail: detail(of: body))
            default:
                throw GeminiError.http(status: response.statusCode, detail: detail(of: body))
            }
        }
        throw failure
    }

    /// A short, scrubbed account of an error body: the service's own message when there is one.
    private func detail(of body: Data) -> String {
        let text = GenerateWireFormat.errorMessage(in: body) ?? String(decoding: body, as: UTF8.self)
        return clean(text)
    }

    private func clean(_ text: String) -> String {
        Scrubber.clean(text, secret: apiKey, limit: config.errorDetailLimit)
    }
}
