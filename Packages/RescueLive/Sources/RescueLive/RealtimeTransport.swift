import Foundation
import RescueCore

/// What a realtime voice provider must do, in provider-neutral terms. Gemini speaks this over a
/// WebSocket. A later OpenAI transport can speak it over WebRTC without `LiveSession` changing.
public protocol RealtimeTransport: Sendable {
    /// Returns at once. Failure arrives later as `.closed` on the connection's stream.
    func connect(_ request: RealtimeConnectRequest) -> any RealtimeConnection
}

/// One connection attempt. A stale one can be closed or fail without touching its replacement.
public protocol RealtimeConnection: Sendable {
    /// Ends after `.closed`. Must stay bounded, never buffer without limit.
    var inbound: AsyncStream<RealtimeInbound> { get }
    func send(_ message: RealtimeOutbound) async throws
    func close()
}

public struct RealtimeConnectRequest: Sendable, Equatable {
    /// Continue an earlier session. Nil starts a new one.
    public var resumeHandle: String?
    /// True when the first message will be a `seed: true` state brief.
    public var seedsHistory: Bool

    public init(resumeHandle: String?, seedsHistory: Bool) {
        self.resumeHandle = resumeHandle
        self.seedsHistory = seedsHistory
    }
}

public enum RealtimeOutbound: Sendable, Equatable {
    /// 16 kHz, 16-bit, little-endian mono PCM.
    case audio(Data)
    case audioStreamEnd
    case frame(jpeg: Data)
    /// `seed` is the first brief after a fresh connect, before any realtime input.
    case stateBrief(StateBrief, seed: Bool)
    case toolResponses([ToolResponse])
    /// Asks the model to speak first, since nothing else prompts it to.
    case kick
}

public enum RealtimeInbound: Sendable, Equatable {
    /// The provider accepted setup. Nothing else may be sent before this.
    case ready
    /// 24 kHz, 16-bit, little-endian mono PCM.
    case audio(Data)
    case interrupted
    case turnComplete
    case inputTranscript(String)
    case outputTranscript(String)
    case functionCalls([RealtimeFunctionCall])
    case functionCallsCancelled([String])
    case goAway(secondsLeft: TimeInterval?)
    case resumption(handle: String?, resumable: Bool)
    case usage(LiveUsage)
    case closed(LiveDisconnectReason)
}

/// A function call as it arrived. Everything in it is untrusted, including its shape.
public struct RealtimeFunctionCall: Sendable, Equatable {
    public var id: String?
    public var name: String?
    public var args: JSONValue?

    public init(id: String?, name: String?, args: JSONValue?) {
        self.id = id
        self.name = name
        self.args = args
    }
}

/// The app's reply to a function call. Contains only fixed values and the call's own id and name,
/// never text from the arguments. Always sent with scheduling SILENT.
public struct ToolResponse: Sendable, Equatable {
    public enum Status: String, Sendable { case received, rejected }

    public enum RejectReason: String, Sendable, CaseIterable {
        case unknownTool = "unknown_tool"
        case missingStateVersion = "missing_state_version"
        case invalidArguments = "invalid_arguments"
        case unknownValue = "unknown_value"
    }

    public var id: String
    public var name: String
    public var status: Status
    public var reason: RejectReason?

    public init(id: String, name: String, status: Status, reason: RejectReason?) {
        self.id = id
        self.name = name
        self.status = status
        self.reason = reason
    }
}

public struct LiveUsage: Sendable, Equatable {
    public var promptTokens: Int?
    public var cachedTokens: Int?
    public var responseTokens: Int?
    public var toolUsePromptTokens: Int?
    public var thoughtsTokens: Int?
    public var totalTokens: Int?

    public init(
        promptTokens: Int? = nil, cachedTokens: Int? = nil, responseTokens: Int? = nil,
        toolUsePromptTokens: Int? = nil, thoughtsTokens: Int? = nil, totalTokens: Int? = nil
    ) {
        self.promptTokens = promptTokens
        self.cachedTokens = cachedTokens
        self.responseTokens = responseTokens
        self.toolUsePromptTokens = toolUsePromptTokens
        self.thoughtsTokens = thoughtsTokens
        self.totalTokens = totalTokens
    }
}

/// Why a connection ended. Holds codes and scrubbed text only, never an underlying `Error`, since
/// URLSession errors carry the URL in their user info.
public enum LiveDisconnectReason: Sendable, Equatable, CustomStringConvertible {
    case stopped
    case goAway
    case setupTimeout
    case closedByServer(code: Int, reason: String?)
    case networkFailure(code: Int?)
    case sendFailed
    /// Retrying cannot help, for example a missing key or malformed tool contract.
    case invalidConfiguration

    public var description: String {
        switch self {
        case .stopped: "stopped"
        case .goAway: "server going away"
        case .setupTimeout: "setup timed out"
        case let .closedByServer(code, reason):
            reason.map { "closed by server, code \(code): \($0)" } ?? "closed by server, code \(code)"
        case let .networkFailure(code):
            code.map { "network failure, code \($0)" } ?? "network failure"
        case .sendFailed: "send failed"
        case .invalidConfiguration: "invalid configuration"
        }
    }
}
