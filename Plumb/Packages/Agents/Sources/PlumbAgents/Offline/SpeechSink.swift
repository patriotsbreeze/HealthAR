import AVFoundation

/// One held press of the button, seen from the recognizer: audio goes in while it is held, and the
/// text comes out once it is let go. Each press gets a new one.
protocol SpeechSink: AnyObject, Sendable {
    /// A buffer from the microphone. Called on the audio thread, so it returns quickly.
    func feed(_ buffer: AVAudioPCMBuffer)
    /// No more audio is coming. Returns what was heard, waiting no longer than `limit` for the last
    /// words; whatever was heard by then is kept.
    func close(within limit: Duration) async -> String?
    /// Throws the press away without waiting for any words, as when the microphone failed to start.
    func cancel()
}
