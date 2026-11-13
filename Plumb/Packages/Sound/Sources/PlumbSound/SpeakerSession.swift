#if os(iOS)
import AVFoundation

/// Asks iOS for output through the speaker at the app's full volume, even with the silent switch on.
/// This package never opens the microphone itself; it only leaves room for the app to, when asked.
enum SpeakerSession {
    /// Sets the category. Done before the engine is built, so the engine sees the hardware format it
    /// will really get. With `sharesMicrophone` the session also allows recording, still routed to
    /// the loudspeaker rather than the earpiece, so the app's push-to-talk can share it.
    static func claim(sharesMicrophone: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if sharesMicrophone {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        } else {
            try session.setCategory(.playback, mode: .default, options: [])
        }
    }

    /// Makes the session live.
    static func activate() throws {
        try AVAudioSession.sharedInstance().setActive(true)
    }

    /// Gives the output back, letting other apps' audio resume. Failing to is harmless, so it is not reported.
    static func release() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif
