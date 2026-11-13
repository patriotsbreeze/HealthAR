import AVFoundation
import Synchronization

/// Speaks phrases with the system voice, into memory rather than out loud.
///
/// The system hands the audio back on the main queue, so the main thread must be free while a
/// phrase renders: await `render` from async code and never block the main thread waiting for it.
public struct SystemCueSpeaker: CueSpeaking {
    private let language: String
    private let rate: Float
    private let timeoutSeconds: Double

    /// Uses the voice language, speaking rate and time limit set in `config`.
    public init(config: BeatEngine.Config = .init()) {
        language = config.cueLanguage
        let span = AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate
        let share = Float(min(1, max(0, config.cueSpeechRate)))
        rate = AVSpeechUtteranceMinimumSpeechRate + share * span
        timeoutSeconds = config.cueRenderTimeoutSeconds
    }

    /// The phrase as spoken by the system voice. Throws if there is no voice or it stays silent.
    public func render(_ text: String) async throws -> MonoClip {
        guard let voice = Self.clearestVoice(for: language) else {
            throw CueSpeechError.noVoice(language: language)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        return try await SpeechCapture().capture(utterance, timeoutSeconds: timeoutSeconds)
    }

    /// An enhanced or premium voice if the user has downloaded one, otherwise the standard voice.
    /// Only ever upgrades: the standard-quality list also holds novelty voices nobody should be coached by.
    private static func clearestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let standard = AVSpeechSynthesisVoiceQuality.default.rawValue
        let upgrade = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language && $0.quality.rawValue > standard }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        return upgrade ?? AVSpeechSynthesisVoice(language: language)
    }
}

/// Collects one phrase's audio from the system synthesizer and hands it over exactly once.
///
/// Unchecked because the synthesizer is not marked sendable. It is safe here: it is created by
/// this object, told to write once and perhaps to stop, and everything else sits behind the lock.
private final class SpeechCapture: @unchecked Sendable {
    private struct Progress {
        var samples: [Float] = []
        var sampleRate: Double = 0
        var waiting: CheckedContinuation<MonoClip, any Error>?
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let progress = Mutex(Progress())

    func capture(_ utterance: AVSpeechUtterance, timeoutSeconds: Double) async throws -> MonoClip {
        // This call keeps `self` alive until it returns. The closures hold it weakly, because the
        // synthesizer keeps its callback and would otherwise hold this object for ever.
        try await withCheckedThrowingContinuation { continuation in
            progress.withLock { $0.waiting = continuation }
            synthesizer.write(utterance) { [weak self] buffer in self?.take(buffer) }
            // Without a limit, a speech service that never answers would leave the caller waiting for ever.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                guard let self, self.finish(failure: .timedOut(seconds: timeoutSeconds)) else { return }
                self.synthesizer.stopSpeaking(at: .immediate)
            }
        }
    }

    private func take(_ buffer: AVAudioBuffer) {
        guard let audio = buffer as? AVAudioPCMBuffer else { return }
        // The synthesizer marks the end of a phrase with an empty buffer.
        guard audio.frameLength > 0 else {
            finish(failure: nil)
            return
        }
        guard let piece = MonoClip(firstChannelOf: audio) else {
            finish(failure: .unreadableAudio)
            return
        }
        progress.withLock {
            $0.samples += piece.samples
            $0.sampleRate = piece.sampleRate
        }
    }

    /// Hands over the result if nobody has yet. Returns whether this call was the one that did.
    @discardableResult
    private func finish(failure: CueSpeechError?) -> Bool {
        let (waiting, clip) = progress.withLock { progress in
            let waiting = progress.waiting
            progress.waiting = nil
            return (waiting, MonoClip(samples: progress.samples, sampleRate: progress.sampleRate))
        }
        guard let waiting else { return false }
        if let failure {
            waiting.resume(throwing: failure)
        } else if clip.samples.isEmpty {
            waiting.resume(throwing: CueSpeechError.noAudio)
        } else {
            waiting.resume(returning: clip)
        }
        return true
    }
}
