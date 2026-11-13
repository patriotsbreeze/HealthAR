import AVFoundation
import Speech

/// One press heard by the older recognizer, held to recognition on the phone so no audio leaves it.
final class RecognizerSink: SpeechSink, @unchecked Sendable {
    // Both written once in init, then only read. The request takes buffers from any thread.
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let task: SFSpeechRecognitionTask
    private let heard = HeardText()

    init(recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        // Partial results are kept so that a recognizer that never finalises still leaves its best
        // guess behind when time runs out.
        request.shouldReportPartialResults = true
        self.request = request
        let heard = self.heard
        task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                heard.replace(with: result.bestTranscription.formattedString)
                if result.isFinal { heard.finish() }
            }
            if error != nil { heard.finish() }
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
    }

    func close(within limit: Duration) async -> String? {
        request.endAudio()
        let heard = self.heard
        if case .overran = await runTimed(within: limit, { await heard.waitUntilFinished() }) {
            task.cancel()
        }
        return heard.text
    }

    func cancel() {
        task.cancel()
    }
}
