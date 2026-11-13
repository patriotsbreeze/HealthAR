import Foundation

// ─────────────────────────────────────────────────────────────────────────────────────────────
// WIRE FORMAT: the live voice socket.
// Every URL, header and JSON field name used by VoiceSession is in this file and nowhere else.
// If the real server disagrees with anything, this is the only file to change.
// The model id and voice name are values in AgentsConfig; how they are spelled on the wire is here.
// Read on 2026-11-11 from the official pages listed in the package report.
// ─────────────────────────────────────────────────────────────────────────────────────────────

/// What one message from the live service means to the voice session.
enum ServerSignal: Sendable, Equatable {
    /// The service accepted the setup. Nothing may be sent before this.
    case setupComplete
    /// A piece of the transcript of what the person said.
    case heard(String)
    /// A piece of the transcript of what the model said.
    case replied(String)
    /// Model speech: 16-bit little-endian mono PCM at 24 kHz.
    case audio(Data)
    /// The model finished its turn.
    case turnComplete
    /// The model asks for a tool to be run.
    case toolCall(id: String?, name: String, argumentsJSON: Data)
    /// The model no longer wants the answers to these calls.
    case toolCallsCancelled(ids: [String])
}

enum WireFormat {
    /// Host shared by the HTTPS endpoints and the live socket.
    static let host = "generativelanguage.googleapis.com"
    /// The key goes in this header for both. The official client library does the same on the
    /// socket handshake, which keeps the key out of the URL.
    static let keyHeader = "x-goog-api-key"
    static let livePath = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    /// Microphone audio: raw 16-bit little-endian mono PCM at 16 kHz.
    static let inputAudioMime = "audio/pcm;rate=16000"
    /// Model audio arrives as `audio/pcm;rate=24000`.
    static let outputAudioMimePrefix = "audio/pcm"

    // MARK: - Client to server

    /// The request that opens the socket.
    static func handshake(apiKey: String, timeout: Duration) -> URLRequest? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = livePath
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout.inSeconds
        request.setValue(apiKey, forHTTPHeaderField: keyHeader)
        return request
    }

    /// The first message on the socket. It fixes the model, the standing instruction and the single
    /// tool for the whole session, and turns automatic voice detection off so that only explicit
    /// start and end of activity open a turn.
    static func setup(config: AgentsConfig, system: String, toolName: String, toolDescription: String) -> JSONValue {
        var generation: [String: JSONValue] = ["responseModalities": ["AUDIO"]]
        if let voice = config.voiceName {
            generation["speechConfig"] = ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": .string(voice)]]]
        }
        return ["setup": [
            "model": .string("models/\(config.liveModel)"),
            "generationConfig": .object(generation),
            "systemInstruction": ["parts": [["text": .string(system)]]],
            // A declaration with no "parameters" member is a tool that takes no arguments.
            "tools": [["functionDeclarations": [["name": .string(toolName), "description": .string(toolDescription)]]]],
            "realtimeInputConfig": ["automaticActivityDetection": ["disabled": true]],
            "inputAudioTranscription": [:],
            "outputAudioTranscription": [:],
        ]]
    }

    /// The person started talking.
    static let activityStart: JSONValue = ["realtimeInput": ["activityStart": [:]]]

    /// The person stopped talking.
    static let activityEnd: JSONValue = ["realtimeInput": ["activityEnd": [:]]]

    /// One chunk of microphone audio.
    static func audio(_ pcm16k: Data) -> JSONValue {
        ["realtimeInput": ["audio": ["data": .string(pcm16k.base64EncodedString()), "mimeType": .string(inputAudioMime)]]]
    }

    /// The answer to a tool call that worked.
    static func toolResult(id: String?, name: String, result: JSONValue) -> JSONValue {
        toolResponse(id: id, name: name, response: ["result": result])
    }

    /// The answer to a tool call that did not work.
    static func toolError(id: String?, name: String, reason: String) -> JSONValue {
        toolResponse(id: id, name: name, response: ["error": .string(reason)])
    }

    private static func toolResponse(id: String?, name: String, response: JSONValue) -> JSONValue {
        var answer: [String: JSONValue] = ["name": .string(name), "response": response]
        if let id { answer["id"] = .string(id) }
        return ["toolResponse": ["functionResponses": [.object(answer)]]]
    }

    // MARK: - Server to client

    /// Reads one frame. The service sends JSON in either text or binary frames. Returns nil when the
    /// frame is not JSON, and an empty list for a message this app has no use for.
    static func signals(in frame: SocketFrame) -> [ServerSignal]? {
        let data: Data
        switch frame {
        case .text(let text): data = Data(text.utf8)
        case .binary(let bytes): data = bytes
        }
        guard let message = try? JSONValue(parsing: data) else { return nil }

        var signals: [ServerSignal] = []
        if message["setupComplete"] != nil {
            signals.append(.setupComplete)
        }
        if let content = message["serverContent"] {
            if let text = content["inputTranscription"]?["text"]?.string, !text.isEmpty {
                signals.append(.heard(text))
            }
            for part in content["modelTurn"]?["parts"]?.array ?? [] {
                guard let blob = part["inlineData"], let encoded = blob["data"]?.string,
                      blob["mimeType"]?.string?.hasPrefix(outputAudioMimePrefix) ?? true,
                      let pcm = Data(base64Encoded: encoded), !pcm.isEmpty else { continue }
                signals.append(.audio(pcm))
            }
            if let text = content["outputTranscription"]?["text"]?.string, !text.isEmpty {
                signals.append(.replied(text))
            }
            if content["turnComplete"]?.bool == true {
                signals.append(.turnComplete)
            }
        }
        for call in message["toolCall"]?["functionCalls"]?.array ?? [] {
            guard let name = call["name"]?.string else { continue }
            let arguments = (try? call["args"]?.encoded()) ?? Data("{}".utf8)
            signals.append(.toolCall(id: call["id"]?.string, name: name, argumentsJSON: arguments))
        }
        if let ids = message["toolCallCancellation"]?["ids"]?.array {
            signals.append(.toolCallsCancelled(ids: ids.compactMap(\.string)))
        }
        return signals
    }
}
