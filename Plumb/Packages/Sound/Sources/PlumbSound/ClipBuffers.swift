import AVFoundation

// The bridge between plain clips and the buffers the audio engine plays.

extension MonoClip {
    /// The clip as a buffer a player node can schedule. Nil for an empty clip or an unusable rate.
    func makeBuffer() -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: source.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    /// Reads the first channel of a buffer, whatever sample type it holds. Nil for a type not handled.
    init?(firstChannelOf buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        // In an interleaved buffer the first channel is every `stride`th value.
        let stride = buffer.stride
        let samples: [Float]
        if let data = buffer.floatChannelData {
            samples = (0..<frames).map { data[0][$0 * stride] }
        } else if let data = buffer.int16ChannelData {
            samples = (0..<frames).map { Float(data[0][$0 * stride]) / 32_768 }
        } else if let data = buffer.int32ChannelData {
            samples = (0..<frames).map { Float(data[0][$0 * stride]) / 2_147_483_648 }
        } else {
            return nil
        }
        self.init(samples: samples, sampleRate: buffer.format.sampleRate)
    }
}
