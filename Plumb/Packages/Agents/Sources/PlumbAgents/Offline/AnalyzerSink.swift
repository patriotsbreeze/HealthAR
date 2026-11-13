import AVFoundation
import Speech

/// One press heard by the newer recognizer (iOS 26), which runs on the phone once its speech model
/// for the language is installed.
///
/// Audio is converted to the recognizer's format and queued from the first buffer, so nothing said
/// while the recognizer is still starting up is lost.
@available(iOS 26.0, macOS 26.0, *)
final class AnalyzerSink: SpeechSink, @unchecked Sendable {
    // Written once in init, then only read. `converter` is used only from the audio thread.
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let converter: BufferConverter
    private let heard = HeardText()
    private let startup: Task<Void, any Error>

    /// Nil when the microphone's format cannot be converted to the recognizer's.
    init?(locale: Locale, analyzerFormat: AVAudioFormat, microphoneFormat: AVAudioFormat) {
        guard let converter = BufferConverter(from: microphoneFormat, to: analyzerFormat) else { return nil }
        self.converter = converter
        // Final results only: a question is short, and only the finished words are classified.
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        self.input = input
        let heard = self.heard
        Task {
            do {
                for try await result in transcriber.results where result.isFinal {
                    heard.append(String(result.text.characters))
                }
            } catch {
                // The words heard before the failure are kept.
            }
            heard.finish()
        }
        startup = Task {
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            try await analyzer.start(inputSequence: stream)
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    func close(within limit: Duration) async -> String? {
        input.finish()
        let analyzer = self.analyzer, startup = self.startup, heard = self.heard
        let outcome = await runTimed(within: limit) {
            try await startup.value
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            await heard.waitUntilFinished()
        }
        if case .finished = outcome {
            return heard.text
        }
        await analyzer.cancelAndFinishNow()
        return heard.text
    }

    func cancel() {
        input.finish()
        let analyzer = self.analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}
