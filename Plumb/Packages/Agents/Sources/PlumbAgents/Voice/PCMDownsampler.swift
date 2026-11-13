import AVFoundation

/// Turns whatever the microphone delivers into the stream the voice service expects: 16 kHz,
/// 16-bit, mono, little-endian PCM, cut into chunks of equal length.
///
/// Not thread-safe. Feed it from one thread, which for a microphone is the audio thread.
final class PCMDownsampler {
    /// The sample rate the voice service takes.
    static let outputSampleRate = 16_000.0

    /// Bytes in every chunk handed out.
    let chunkBytes: Int
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let ratio: Double
    /// Converted bytes not yet long enough to make a chunk.
    private var pending = Data()

    /// Nil when the input format cannot be converted.
    init?(inputFormat: AVAudioFormat, chunkMs: Int) {
        // Int16 here is in the host's byte order, which is little-endian on every Apple platform.
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.outputSampleRate,
                                               channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              inputFormat.sampleRate > 0, chunkMs > 0 else { return nil }
        self.outputFormat = outputFormat
        self.converter = converter
        ratio = Self.outputSampleRate / inputFormat.sampleRate
        chunkBytes = Int(Self.outputSampleRate) * chunkMs / 1000 * MemoryLayout<Int16>.size
    }

    /// Converts one buffer and returns every whole chunk now available, oldest first.
    func feed(_ buffer: AVAudioPCMBuffer) -> [Data] {
        // A little headroom, because the resampler does not hand back an exact share each time.
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard buffer.frameLength > 0, let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return []
        }
        // The converter pulls its input. It is given this buffer once and then told there is no
        // more for now, which keeps its filter state ready for the next buffer.
        let source = OneBuffer(buffer)
        var failure: NSError?
        let status = converter.convert(to: converted, error: &failure) { _, inputStatus in
            guard let next = source.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return next
        }
        guard status != .error, converted.frameLength > 0, let samples = converted.int16ChannelData else { return [] }
        pending.append(UnsafeBufferPointer(start: samples[0], count: Int(converted.frameLength)))

        var chunks: [Data] = []
        while pending.count >= chunkBytes {
            chunks.append(pending.prefix(chunkBytes))
            pending = Data(pending.dropFirst(chunkBytes))
        }
        return chunks
    }
}

/// Hands a buffer out exactly once. A class so the converter's input callback can share it.
private final class OneBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
