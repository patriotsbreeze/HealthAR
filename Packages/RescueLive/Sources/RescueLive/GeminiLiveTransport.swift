import Foundation

public struct GeminiLiveConfiguration: Sendable {
    public enum KeyPlacement: Sendable {
        /// `x-goog-api-key`. Google's Python SDK sends the key this way on the socket, though the
        /// WebSocket guide documents only the query parameter. See the device checks.
        case header
        case queryParameter
    }

    public static let defaultModel = "gemini-3.8-live"

    public var apiKey: APIKey
    public var toolContract: Data
    public var keyPlacement: KeyPlacement = .header
    public var model = GeminiLiveConfiguration.defaultModel
    public var systemInstruction = SystemPrompt.text
    /// The prebuilt voice the phrase clips are rendered in, GEMINI_VOICE, so the app's lines and
    /// the AI sound alike. Nil keeps the model's default voice.
    public var voiceName: String? = nil

    public init(apiKey: APIKey, toolContract: Data) {
        self.apiKey = apiKey
        self.toolContract = toolContract
    }
}

/// Gemini Live over `URLSessionWebSocketTask`.
public struct GeminiLiveTransport: RealtimeTransport {
    private let configuration: GeminiLiveConfiguration
    private let makeSocket: @Sendable (URLRequest) -> any LiveSocket
    /// Shared, since a URLSession lives until it's invalidated and each swap makes a transport.
    private static let session = URLSession(configuration: .ephemeral)

    public init(configuration: GeminiLiveConfiguration) {
        self.init(configuration: configuration) { URLSessionLiveSocket(session: Self.session, request: $0) }
    }

    init(configuration: GeminiLiveConfiguration, makeSocket: @escaping @Sendable (URLRequest) -> any LiveSocket) {
        self.configuration = configuration
        self.makeSocket = makeSocket
    }

    public func connect(_ request: RealtimeConnectRequest) -> any RealtimeConnection {
        guard !configuration.apiKey.isEmpty,
              let urlRequest = Self.urlRequest(configuration),
              let declarations = try? LiveSetup.functionDeclarations(fromContract: configuration.toolContract),
              let setupText = try? LiveClientMessage.setup(LiveSetup(
                  model: configuration.model,
                  systemInstruction: configuration.systemInstruction,
                  functionDeclarations: declarations,
                  resumeHandle: request.resumeHandle,
                  seedsHistory: request.seedsHistory,
                  voiceName: configuration.voiceName
              )).encodedText()
        else {
            return GeminiLiveConnection(failedWith: .invalidConfiguration)
        }
        return GeminiLiveConnection(
            socket: makeSocket(urlRequest),
            setupText: setupText,
            apiKey: configuration.apiKey
        )
    }

    // Holds the key. Never log or print this request or its URL.
    static func urlRequest(_ configuration: GeminiLiveConfiguration) -> URLRequest? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "generativelanguage.googleapis.com"
        components.path = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        if configuration.keyPlacement == .queryParameter {
            components.queryItems = [URLQueryItem(name: "key", value: configuration.apiKey.value)]
        }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        if configuration.keyPlacement == .header {
            request.setValue(configuration.apiKey.value, forHTTPHeaderField: "x-goog-api-key")
        }
        return request
    }
}

final class GeminiLiveConnection: RealtimeConnection {
    let inbound: AsyncStream<RealtimeInbound>
    private let socket: (any LiveSocket)?
    private let receiveTask: Task<Void, Never>?

    init(socket: any LiveSocket, setupText: String, apiKey: APIKey) {
        let (stream, continuation) = AsyncStream.makeStream(of: RealtimeInbound.self, bufferingPolicy: .bufferingNewest(512))
        inbound = stream
        self.socket = socket
        receiveTask = Task {
            do {
                try await socket.send(setupText)
                while !Task.isCancelled {
                    let frame = try await socket.receive()
                    // A frame that doesn't parse is ignored. Only the socket closing ends this.
                    guard let message = GeminiCodec.decode(frame) else { continue }
                    for event in GeminiCodec.inbound(from: message) { continuation.yield(event) }
                }
            } catch {
                if !Task.isCancelled {
                    continuation.yield(.closed(Self.reason(for: error, socket: socket, apiKey: apiKey)))
                }
            }
            continuation.finish()
        }
    }

    init(failedWith reason: LiveDisconnectReason) {
        let (stream, continuation) = AsyncStream.makeStream(of: RealtimeInbound.self)
        continuation.yield(.closed(reason))
        continuation.finish()
        inbound = stream
        socket = nil
        receiveTask = nil
    }

    func send(_ message: RealtimeOutbound) async throws {
        guard let socket else { throw URLError(.notConnectedToInternet) }
        try await socket.send(try GeminiCodec.clientMessage(for: message).encodedText())
    }

    func close() {
        receiveTask?.cancel()
        socket?.cancel()
    }

    /// Keeps only a code from the error, because its user info can hold the URL and so the key.
    static func reason(for error: any Error, socket: any LiveSocket, apiKey: APIKey) -> LiveDisconnectReason {
        if let closed = socket.closeInfo {
            // Scrub before cutting, so that a cut can't leave part of the key behind.
            let text = closed.reason.map { String(apiKey.scrubbed(String(decoding: $0, as: UTF8.self)).prefix(200)) }
            return .closedByServer(code: closed.code, reason: text?.isEmpty == false ? text : nil)
        }
        return .networkFailure(code: (error as? URLError)?.code.rawValue)
    }
}

/// The socket `GeminiLiveConnection` needs, so that tests can run it without a network.
protocol LiveSocket: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> Data
    func cancel()
    var closeInfo: (code: Int, reason: Data?)? { get }
}

final class URLSessionLiveSocket: LiveSocket {
    private let task: URLSessionWebSocketTask

    init(session: URLSession, request: URLRequest) {
        task = session.webSocketTask(with: request)
        // The default 1 MiB limit is close to a large base64 audio chunk.
        task.maximumMessageSize = 8 * 1024 * 1024
        task.resume()
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    /// The docs don't say which frame type carries the JSON, so both are read the same way.
    func receive() async throws -> Data {
        switch try await task.receive() {
        case let .data(data): data
        case let .string(text): Data(text.utf8)
        @unknown default: Data()
        }
    }

    func cancel() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    var closeInfo: (code: Int, reason: Data?)? {
        task.closeCode == .invalid ? nil : (task.closeCode.rawValue, task.closeReason)
    }
}
