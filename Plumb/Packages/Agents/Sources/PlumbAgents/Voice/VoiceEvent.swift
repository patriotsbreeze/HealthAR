import Foundation

/// What the voice session tells the app.
public enum VoiceEvent: Sendable, Equatable {
    /// The service accepted the session. Talking can begin.
    case connected
    /// The session is over. The reason is plain words and never contains the key.
    case disconnected(reason: String)
    /// A piece of what the person said, as the service transcribed it.
    case heard(text: String)
    /// A piece of what the model said, as the service transcribed it. For captions and the log.
    case replied(text: String)
    /// Model speech to play: 16-bit little-endian mono PCM at 24 kHz.
    case speaking(pcm24k: Data)
    /// The model asked for a tool. The call itself is already running through the Conductor.
    case toolCalled(name: String)
    /// The model finished its turn.
    case turnEnded
    /// Something went wrong that the app may want to show. Plain words, never the key.
    case failed(reason: String)
}
