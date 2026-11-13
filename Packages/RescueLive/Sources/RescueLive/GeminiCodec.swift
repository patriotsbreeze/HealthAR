import Foundation
import RescueCore

/// Pure translation between Gemini's wire format and the provider-neutral transport types.
enum GeminiCodec {
    static func decode(_ frame: Data) -> LiveServerMessage? {
        try? JSONDecoder().decode(LiveServerMessage.self, from: frame)
    }

    static func clientMessage(for outbound: RealtimeOutbound) -> LiveClientMessage {
        switch outbound {
        case let .audio(pcm): .realtimeAudio(pcm16k: pcm)
        case .audioStreamEnd: .audioStreamEnd
        case let .frame(jpeg): .realtimeVideo(jpeg: jpeg)
        case let .stateBrief(brief, seed): stateBriefMessage(brief, seed: seed)
        case let .toolResponses(responses): .toolResponse(responses)
        case .kick: kickMessage()
        }
    }

    /// The one place that decides how a StateBrief reaches the model. Whether this works
    /// mid-session on gemini-3.8-live is a device check, because the docs disagree. A seed uses
    /// `turnComplete: true`, which ends initial history and does not trigger a model call. A
    /// later brief uses `false`, so that it adds context without asking for a reply.
    static func stateBriefMessage(_ brief: StateBrief, seed: Bool) -> LiveClientMessage {
        .clientContent(turns: [LiveTextTurn(role: "user", text: brief.text)], turnComplete: seed)
    }

    /// A seed's `turnComplete: true` ends initial history. This one comes after the seed, so it asks
    /// for a reply. Client content may interrupt generation, so it's sent once, and only into a quiet session.
    static func kickMessage() -> LiveClientMessage {
        .clientContent(turns: [LiveTextTurn(role: "user", text: SystemPrompt.awakeKick)], turnComplete: true)
    }

    /// Audio comes before the flags, so that a flush on `interrupted` also covers it.
    static func inbound(from message: LiveServerMessage) -> [RealtimeInbound] {
        var events: [RealtimeInbound] = []
        if message.setupComplete { events.append(.ready) }
        if let content = message.serverContent {
            for part in content.parts {
                if let data = part.inlineData, part.mimeType?.hasPrefix("audio/") ?? false {
                    events.append(.audio(data))
                }
            }
            if let text = content.inputTranscription { events.append(.inputTranscript(text)) }
            if let text = content.outputTranscription { events.append(.outputTranscript(text)) }
            if content.interrupted { events.append(.interrupted) }
            if content.turnComplete { events.append(.turnComplete) }
        }
        if let calls = message.functionCalls { events.append(.functionCalls(calls)) }
        if let ids = message.cancelledCallIDs { events.append(.functionCallsCancelled(ids)) }
        if let update = message.sessionResumptionUpdate {
            events.append(.resumption(handle: update.newHandle, resumable: update.resumable))
        }
        if let usage = message.usage { events.append(.usage(usage)) }
        // Last, since the session reconnects on this and ignores the rest of the connection.
        if let goAway = message.goAway { events.append(.goAway(secondsLeft: goAway.secondsLeft)) }
        return events
    }
}
