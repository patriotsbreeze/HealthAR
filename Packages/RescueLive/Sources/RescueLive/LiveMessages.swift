import Foundation

/// A client message, in the BidiGenerateContent wire format.
public enum LiveClientMessage: Sendable, Equatable, Encodable {
    case setup(LiveSetup)
    case realtimeAudio(pcm16k: Data)
    case realtimeVideo(jpeg: Data)
    case audioStreamEnd
    case clientContent(turns: [LiveTextTurn], turnComplete: Bool)
    case toolResponse([ToolResponse])

    public func encode(to encoder: any Encoder) throws {
        try jsonValue.encode(to: encoder)
    }

    public func encodedText() throws -> String {
        String(decoding: try jsonValue.encoded(), as: UTF8.self)
    }

    var jsonValue: JSONValue {
        switch self {
        case let .setup(setup):
            ["setup": setup.jsonValue]
        case let .realtimeAudio(pcm):
            ["realtimeInput": ["audio": Self.blob(pcm, mimeType: "audio/pcm;rate=16000")]]
        case let .realtimeVideo(jpeg):
            ["realtimeInput": ["video": Self.blob(jpeg, mimeType: "image/jpeg")]]
        case .audioStreamEnd:
            ["realtimeInput": ["audioStreamEnd": true]]
        case let .clientContent(turns, turnComplete):
            ["clientContent": [
                "turns": .array(turns.map(\.jsonValue)),
                "turnComplete": .bool(turnComplete),
            ]]
        case let .toolResponse(responses):
            ["toolResponse": ["functionResponses": .array(responses.map(Self.functionResponse))]]
        }
    }

    private static func blob(_ data: Data, mimeType: String) -> JSONValue {
        ["mimeType": .string(mimeType), "data": .string(data.base64EncodedString())]
    }

    // The tools page puts scheduling inside `response`, and the API reference lists it as a
    // field of FunctionResponse. Both are valid against their own page, so both are sent.
    private static func functionResponse(_ response: ToolResponse) -> JSONValue {
        var body: [String: JSONValue] = [
            "status": .string(response.status.rawValue),
            "retryable": false,
            "scheduling": "SILENT",
        ]
        switch response.status {
        case .received:
            body["message"] = "Received. The app decides what happens next."
        case .rejected:
            body["message"] = "Not accepted. Use only declared tools and values, and quote state_version from the latest STATE BRIEF."
        }
        if let reason = response.reason { body["reason"] = .string(reason.rawValue) }
        return [
            "id": .string(response.id),
            "name": .string(response.name),
            "scheduling": "SILENT",
            "response": .object(body),
        ]
    }
}

public struct LiveTextTurn: Sendable, Equatable {
    public var role: String
    public var text: String

    public init(role: String, text: String) {
        self.role = role
        self.text = text
    }

    var jsonValue: JSONValue {
        ["role": .string(role), "parts": [["text": .string(text)]]]
    }
}

/// A server message. Several fields can appear in one message, so this is not an enum. Each field
/// decodes on its own: an unknown field is ignored, and a malformed one is treated as absent
/// without losing the rest of the message.
public struct LiveServerMessage: Sendable, Equatable, Decodable {
    public var setupComplete = false
    public var serverContent: ServerContent?
    public var functionCalls: [RealtimeFunctionCall]?
    public var cancelledCallIDs: [String]?
    public var goAway: GoAway?
    public var sessionResumptionUpdate: SessionResumptionUpdate?
    public var usage: LiveUsage?

    public struct ServerContent: Sendable, Equatable, Decodable {
        public var parts: [Part] = []
        public var interrupted = false
        public var generationComplete = false
        public var turnComplete = false
        public var inputTranscription: String?
        public var outputTranscription: String?

        public struct Part: Sendable, Equatable, Decodable {
            public var text: String?
            public var mimeType: String?
            public var inlineData: Data?

            private enum CodingKeys: String, CodingKey { case text, inlineData }
            private enum BlobKeys: String, CodingKey { case mimeType, data }

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                text = try? c.decodeIfPresent(String.self, forKey: .text)
                if let blob = try? c.nestedContainer(keyedBy: BlobKeys.self, forKey: .inlineData) {
                    mimeType = try? blob.decodeIfPresent(String.self, forKey: .mimeType)
                    // Invalid base64 becomes nil rather than failing the message.
                    let base64 = try? blob.decodeIfPresent(String.self, forKey: .data)
                    inlineData = base64.flatMap { Data(base64Encoded: $0) }
                }
            }
        }

        private enum CodingKeys: String, CodingKey {
            case modelTurn, interrupted, generationComplete, turnComplete
            case inputTranscription, outputTranscription
        }
        private enum TurnKeys: String, CodingKey { case parts }
        private enum TranscriptionKeys: String, CodingKey { case text }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let turn = try? c.nestedContainer(keyedBy: TurnKeys.self, forKey: .modelTurn) {
                parts = (try? turn.decodeIfPresent([Part].self, forKey: .parts)) ?? []
            }
            interrupted = (try? c.decodeIfPresent(Bool.self, forKey: .interrupted)) ?? false
            generationComplete = (try? c.decodeIfPresent(Bool.self, forKey: .generationComplete)) ?? false
            turnComplete = (try? c.decodeIfPresent(Bool.self, forKey: .turnComplete)) ?? false
            inputTranscription = Self.transcript(c, .inputTranscription)
            outputTranscription = Self.transcript(c, .outputTranscription)
        }

        private static func transcript(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
            let nested = try? c.nestedContainer(keyedBy: TranscriptionKeys.self, forKey: key)
            return try? nested?.decodeIfPresent(String.self, forKey: .text)
        }
    }

    public struct GoAway: Sendable, Equatable {
        public var secondsLeft: TimeInterval?
    }

    public struct SessionResumptionUpdate: Sendable, Equatable, Decodable {
        public var newHandle: String?
        public var resumable = false

        private enum CodingKeys: String, CodingKey { case newHandle, resumable }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            newHandle = try? c.decodeIfPresent(String.self, forKey: .newHandle)
            resumable = (try? c.decodeIfPresent(Bool.self, forKey: .resumable)) ?? false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case setupComplete, serverContent, toolCall, toolCallCancellation, goAway
        case sessionResumptionUpdate, usageMetadata
    }
    private enum ToolCallKeys: String, CodingKey { case functionCalls }
    private enum CancellationKeys: String, CodingKey { case ids }
    private enum GoAwayKeys: String, CodingKey { case timeLeft }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        setupComplete = c.contains(.setupComplete)
        serverContent = try? c.decodeIfPresent(ServerContent.self, forKey: .serverContent)
        if let toolCall = try? c.nestedContainer(keyedBy: ToolCallKeys.self, forKey: .toolCall) {
            let calls = try? toolCall.decodeIfPresent([WireFunctionCall].self, forKey: .functionCalls)
            functionCalls = calls?.map(\.call)
        }
        if let cancellation = try? c.nestedContainer(keyedBy: CancellationKeys.self, forKey: .toolCallCancellation) {
            cancelledCallIDs = (try? cancellation.decodeIfPresent([String].self, forKey: .ids)) ?? []
        }
        if c.contains(.goAway) {
            let nested = try? c.nestedContainer(keyedBy: GoAwayKeys.self, forKey: .goAway)
            goAway = GoAway(secondsLeft: nested.flatMap { Self.seconds($0) })
        }
        sessionResumptionUpdate = try? c.decodeIfPresent(SessionResumptionUpdate.self, forKey: .sessionResumptionUpdate)
        usage = (try? c.decodeIfPresent(WireUsage.self, forKey: .usageMetadata))?.usage
    }

    /// `timeLeft` is a protobuf Duration, which is a string such as "57s" in JSON.
    private static func seconds(_ c: KeyedDecodingContainer<GoAwayKeys>) -> TimeInterval? {
        if let text = try? c.decodeIfPresent(String.self, forKey: .timeLeft) {
            return text.hasSuffix("s") ? TimeInterval(text.dropLast()) : TimeInterval(text)
        }
        return try? c.decodeIfPresent(Double.self, forKey: .timeLeft)
    }

    private struct WireFunctionCall: Decodable {
        let call: RealtimeFunctionCall

        private enum CodingKeys: String, CodingKey { case id, name, args }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            call = RealtimeFunctionCall(
                id: try? c.decodeIfPresent(String.self, forKey: .id),
                name: try? c.decodeIfPresent(String.self, forKey: .name),
                args: try? c.decodeIfPresent(JSONValue.self, forKey: .args)
            )
        }
    }

    private struct WireUsage: Decodable {
        let usage: LiveUsage

        private enum CodingKeys: String, CodingKey {
            case promptTokenCount, cachedContentTokenCount, responseTokenCount
            case toolUsePromptTokenCount, thoughtsTokenCount, totalTokenCount
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func count(_ key: CodingKeys) -> Int? { try? c.decodeIfPresent(Int.self, forKey: key) }
            usage = LiveUsage(
                promptTokens: count(.promptTokenCount),
                cachedTokens: count(.cachedContentTokenCount),
                responseTokens: count(.responseTokenCount),
                toolUsePromptTokens: count(.toolUsePromptTokenCount),
                thoughtsTokens: count(.thoughtsTokenCount),
                totalTokens: count(.totalTokenCount)
            )
        }
    }
}
