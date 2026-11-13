#if os(macOS)
import AVFoundation
import Foundation
import Testing
@testable import PlumbAgents

/// Runs the newer recognizer for real on a Mac, on a question spoken by the system voice. Off by
/// default, because it needs the speech model for the language installed or downloadable; run with
/// PLUMB_ON_DEVICE_SPEECH=1 to try it.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PLUMB_ON_DEVICE_SPEECH"] == "1"))
struct OnDeviceSpeechLiveTests {
    @Test func theNewerRecognizerHearsASpokenQuestion() async throws {
        guard #available(macOS 26.0, *) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plumb-offline-question.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "How fast am I going?"]
        try say.run()
        say.waitUntilExit()
        let file = try AVAudioFile(forReading: url)
        let (locale, format) = try await OnDeviceTranscriber.prepareAnalyzer(locale: Locale(identifier: "en-US")).get()
        let sink = try #require(AnalyzerSink(locale: locale, analyzerFormat: format, microphoneFormat: file.processingFormat))

        // In buffers of a tenth of a second, as the microphone tap delivers them.
        let frames = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        while file.framePosition < file.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
            try file.read(into: buffer)
            sink.feed(buffer)
        }
        let heard = await sink.close(within: .seconds(10))

        let words = KeywordIntentClassifier.words(in: heard ?? "")
        #expect(words.contains("fast"), "\(heard ?? "nothing")")
        #expect(KeywordIntentClassifier().intent(for: heard ?? "") == .rate)
    }
}
#endif
