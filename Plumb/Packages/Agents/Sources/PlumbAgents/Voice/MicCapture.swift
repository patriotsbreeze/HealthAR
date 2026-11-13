import AVFoundation

/// Captures the microphone as 16 kHz, 16-bit, mono, little-endian PCM in short chunks, ready for
/// `VoiceSession.sendAudio`.
///
/// It owns its own audio engine and nothing else. It does not ask for permission and does not set
/// the audio session category: the app does both before calling `start()`.
public final class MicCapture {
    /// Why capture could not start.
    public enum Failure: Error, Equatable {
        /// There is no microphone input, or the app has no permission to use it.
        case noInput
        /// The microphone's format could not be converted.
        case unsupportedFormat
    }

    private let engine = AVAudioEngine()
    private let chunkMs: Int
    private let onChunk: @Sendable (Data) -> Void
    private var running = false

    /// - Parameter onChunk: receives each chunk of about `micChunkMs` milliseconds. Called on the
    ///   audio thread, so it must return quickly.
    public init(config: AgentsConfig = AgentsConfig(), onChunk: @escaping @Sendable (Data) -> Void) {
        chunkMs = config.micChunkMs
        self.onChunk = onChunk
    }

    /// Starts capturing. Does nothing when already running.
    public func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
        guard let downsampler = PCMDownsampler(inputFormat: format, chunkMs: chunkMs) else {
            throw Failure.unsupportedFormat
        }
        let onChunk = self.onChunk
        // Ask for buffers about one chunk long. The system may hand over longer ones, which the
        // downsampler cuts up.
        let frames = AVAudioFrameCount(format.sampleRate * Double(chunkMs) / 1000)
        input.installTap(onBus: 0, bufferSize: frames, format: format) { buffer, _ in
            for chunk in downsampler.feed(buffer) {
                onChunk(chunk)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
    }

    /// Stops capturing. Does nothing when not running.
    public func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }
}
