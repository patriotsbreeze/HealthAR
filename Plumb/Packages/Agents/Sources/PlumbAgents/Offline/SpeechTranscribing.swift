import Foundation

/// Push-to-talk speech to text: listen while a button is held, then hand back what was said.
///
/// Main actor only, because `begin()` must start the microphone the moment the button goes down.
@MainActor
public protocol SpeechTranscribing: AnyObject {
    /// Finds a way to listen on this phone and gets it ready. Safe to call again; it tries again
    /// when it was not ready before.
    @discardableResult
    func prepare() async -> TranscriberReadiness
    /// The button went down. Starts listening at once.
    func begin() throws
    /// The button came up. Stops listening and returns what was said, or nil when nothing was heard.
    func finish() async -> String?
}

/// Which recognizer turns speech into text. Both run on the phone, with no network.
public enum SpeechEngine: String, Sendable, Equatable {
    /// The newer recognizer, from iOS 26.
    case speechAnalyzer
    /// The older recognizer, held to on-device recognition.
    case speechRecognizer
}

/// Whether questions can be heard, and how.
public enum TranscriberReadiness: Sendable, Equatable {
    case ready(SpeechEngine)
    /// Nothing on this phone can hear questions right now. The reason is plain words.
    case unavailable(reason: String)

    /// True when questions can be heard.
    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}
