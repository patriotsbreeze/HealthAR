import PlumbContracts

/// Something that can turn a phrase into audio ahead of time, so that playing it later is instant.
public protocol CueSpeaking: Sendable {
    /// The phrase as mono audio, at whatever sample rate the voice uses.
    /// Throws when no audio could be made; the cue then falls back to tones.
    func render(_ text: String) async throws -> MonoClip
}

/// The words spoken for each cue. A fixed table: no model ever writes or changes them.
public enum CuePhrasebook {
    /// What is said aloud for a cue.
    public static func spokenText(for cue: Cue) -> String {
        switch cue {
        case .pushNow: "Push now"
        case .pushHarder: "Push harder"
        case .faster: "Faster"
        case .slower: "Slower"
        case .good: "Good compressions"
        }
    }
}

/// Why a phrase could not be turned into speech.
public enum CueSpeechError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No voice is installed for the language asked for.
    case noVoice(language: String)
    /// The speech service produced nothing within the time allowed.
    case timedOut(seconds: Double)
    /// The speech service finished but gave no sound.
    case noAudio
    /// The speech arrived in a sample type or at a sample rate this package cannot read.
    case unreadableAudio

    /// One plain sentence saying what went wrong.
    public var description: String {
        switch self {
        case .noVoice(let language):
            "No voice is installed for \(language)."
        case .timedOut(let seconds):
            "The speech service gave nothing within \(seconds) seconds."
        case .noAudio:
            "The speech service finished without any sound."
        case .unreadableAudio:
            "The speech arrived in a form that could not be read."
        }
    }
}
