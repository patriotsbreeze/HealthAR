import AVFoundation
import PlumbSound

/// The app's own voice for whole sentences: the handoff read aloud, and the fixed answer to a question
/// asked without the network.
@MainActor
final class Narrator {
    private let synthesizer = AVSpeechSynthesizer()
    private let beat: BeatEngine
    /// The voice the cues are spoken in, so an answer sounds like the rest of the coaching.
    private let cueVoice: SystemCueSpeaker

    init(beat: BeatEngine) {
        self.beat = beat
        cueVoice = SystemCueSpeaker(config: beat.config)
    }

    /// Reads the text straight out. Used on the handoff screen, after the beat has stopped.
    func say(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    /// Reads a fixed answer while the rescue goes on, under the cues: it plays where the voice model's
    /// speech plays, so a cue cuts it off and it never holds a cue back. With the beat stopped there is
    /// no cue to keep clear of, so it is read straight out.
    func answer(_ text: String) {
        guard beat.isRunning else {
            say(text)
            return
        }
        Task { [beat, cueVoice] in
            // A phrase the system voice cannot render is not said; the answer is still in the record.
            guard let speech = try? await cueVoice.render(text) else { return }
            beat.playSpeech(speech)
        }
    }
}
