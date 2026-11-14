import Foundation

public enum LiveConfigurationError: Error, Equatable, CustomStringConvertible {
    case invalidToolContract

    public var description: String { "invalid tool contract" }
}

/// The session configuration, sent as the first message on every connection.
public struct LiveSetup: Sendable, Equatable {
    public var model: String
    public var systemInstruction: String
    public var functionDeclarations: [JSONValue]
    public var resumeHandle: String?
    public var seedsHistory: Bool
    /// A prebuilt voice, such as "Kore". Nil leaves the model's default and sends no speechConfig.
    public var voiceName: String?

    public init(
        model: String,
        systemInstruction: String,
        functionDeclarations: [JSONValue],
        resumeHandle: String?,
        seedsHistory: Bool,
        voiceName: String? = nil
    ) {
        self.model = model
        self.systemInstruction = systemInstruction
        self.functionDeclarations = functionDeclarations
        self.resumeHandle = resumeHandle
        self.seedsHistory = seedsHistory
        self.voiceName = voiceName
    }

    /// Reads `contracts/tools.v1.json`. Sets `behavior` on every function, whatever the file says,
    /// since the docs disagree on the default and a blocking call would stall the session.
    public static func functionDeclarations(fromContract data: Data) throws -> [JSONValue] {
        let contract = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard case let .object(root)? = contract,
              case let .array(declarations)? = root["function_declarations"],
              !declarations.isEmpty
        else { throw LiveConfigurationError.invalidToolContract }

        return try declarations.map { declaration in
            guard case var .object(fields) = declaration, case .string? = fields["name"] else {
                throw LiveConfigurationError.invalidToolContract
            }
            fields["behavior"] = "NON_BLOCKING"
            return .object(fields)
        }
    }

    /// How long a sound has to last before the model takes it as someone starting to talk.
    static let speechPrefixMilliseconds: Double = 400

    var jsonValue: JSONValue {
        // Under generationConfig per the API reference, though the WebSocket guide's sample
        // shows responseModalities directly under setup. See the device checks.
        var generation: [String: JSONValue] = [
            "responseModalities": ["AUDIO"],
            "mediaResolution": "MEDIA_RESOLUTION_LOW",
        ]
        // Here in the client setup, never in an ephemeral token's config, which doesn't honor it.
        if let voiceName, !voiceName.isEmpty {
            generation["speechConfig"] = ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": .string(voiceName)]]]
        }
        var fields: [String: JSONValue] = [
            "model": .string("models/\(model)"),
            "generationConfig": .object(generation),
            "systemInstruction": ["parts": [["text": .string(systemInstruction)]]],
            "tools": [["functionDeclarations": .array(functionDeclarations)]],
            // Audio plus video sessions otherwise end at 2 minutes.
            "contextWindowCompression": ["slidingWindow": [:]],
            "sessionResumption": resumeHandle.map { ["handle": .string($0)] } ?? [:],
            "inputAudioTranscription": [:],
            "outputAudioTranscription": [:],
            // The model stops talking the moment it hears speech start, and by default nearly any sound
            // counts, so in a busy room chatter, a cough or its own echo cut it off mid-sentence. Low
            // sensitivity, and speech that has to last 0.4 s, keep it talking through those while a real
            // question still stops it. Accepted by gemini-3.8-live, which rejects unknown values.
            "realtimeInputConfig": ["automaticActivityDetection": [
                "startOfSpeechSensitivity": "START_SENSITIVITY_LOW",
                "prefixPaddingMs": .number(Self.speechPrefixMilliseconds),
            ]],
        ]
        if seedsHistory {
            fields["historyConfig"] = ["initialHistoryInClientContent": true]
        }
        return .object(fields)
    }
}
