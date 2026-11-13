import AVFoundation

/// Converts microphone buffers into the format a recognizer takes, one new buffer for each.
///
/// Every result is a buffer of its own, so it can wait in a queue after the audio thread has moved
/// on and reused the buffer it came from. Not thread-safe: feed it from the audio thread only.
final class BufferConverter {
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let ratio: Double

    /// Nil when there is no way to convert between the two formats.
    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0, outputFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        self.outputFormat = outputFormat
        self.converter = converter
        ratio = outputFormat.sampleRate / inputFormat.sampleRate
    }

    /// The buffer in the output format, or nil when it was empty or could not be converted.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // A little headroom, because the resampler does not hand back an exact share each time.
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard buffer.frameLength > 0,
              let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        // The converter pulls its input. It gets this buffer once and is then told there is no more
        // for now, which keeps its filter state ready for the next buffer.
        var given = false
        var failure: NSError?
        let status = converter.convert(to: converted, error: &failure) { _, inputStatus in
            guard !given else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, converted.frameLength > 0 else { return nil }
        return converted
    }
}
