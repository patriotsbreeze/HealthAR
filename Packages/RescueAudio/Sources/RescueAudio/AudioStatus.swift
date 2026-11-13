import RescueCore

/// What the UI needs to know. Guidance keeps going through all of these.
public enum AudioStatus: Sendable, Equatable {
    /// Sound is reaching the output, in this mode.
    case running(AudioMode)
    /// No sound is reaching the output. Show a visual pulse until `running` returns.
    case outputLost(reason: String)
    /// Mic or voice processing is unavailable. Metronome and phrases still play.
    case micUnavailable(reason: String)
    /// This phrase has no clip, so on-device speech is saying its text.
    case phraseUsingSpeech(id: String)
    /// This phrase could not be voiced at all. Show its text.
    case phraseFailed(id: String)
    /// Read Aloud could not be voiced. Show the script.
    case readAloudFailed
    /// A model turn hit the 20 s limit, and the rest of it is being dropped.
    case runawayTurnStopped
}
