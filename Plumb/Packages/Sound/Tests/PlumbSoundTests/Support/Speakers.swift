import AVFoundation
import PlumbContracts
import Synchronization
@testable import PlumbSound

/// A stand-in voice that "speaks" each phrase as a steady tone of its own pitch, at a speech-like
/// sample rate, so tests can tell by ear which cue is playing.
struct ToneSpeaker: CueSpeaking {
    var seconds = 0.6
    var sampleRate = 22_050.0

    static func hertz(for cue: Cue) -> Double {
        switch cue {
        case .pushNow: 400
        case .pushHarder: 600
        case .faster: 800
        case .slower: 1000
        case .good: 1200
        }
    }

    func render(_ text: String) async throws -> MonoClip {
        guard let cue = Cue.allCases.first(where: { CuePhrasebook.spokenText(for: $0) == text }) else {
            throw CueSpeechError.noAudio
        }
        return MonoClip(samples: sine(hertz: Self.hertz(for: cue), seconds: seconds, sampleRate: sampleRate),
                        sampleRate: sampleRate)
    }
}

/// A stand-in voice that fails in a chosen way for chosen phrases and counts how often it is asked.
final class FailingSpeaker: CueSpeaking {
    private let failure: CueSpeechError
    private let failingPhrases: Set<String>?
    private let asked = Atomic<Int>(0)

    /// Fails for `phrases`, or for every phrase when nil.
    init(failure: CueSpeechError, phrases: Set<String>? = nil) {
        self.failure = failure
        failingPhrases = phrases
    }

    var timesAsked: Int { asked.load(ordering: .relaxed) }

    func render(_ text: String) async throws -> MonoClip {
        asked.add(1, ordering: .relaxed)
        if failingPhrases?.contains(text) ?? true { throw failure }
        return try await ToneSpeaker().render(text)
    }
}

/// An engine wired for offline output, started or not, that tests pull audio from by hand.
func offlineEngine(config: BeatEngine.Config = .init(), targets: Targets = .adult,
                   speaker: any CueSpeaking = ToneSpeaker(),
                   blockFrames: AVAudioFrameCount = 512) -> BeatEngine {
    BeatEngine(targets: targets, config: config, speaker: speaker, output: .offline(maximumFrames: blockFrames))
}
