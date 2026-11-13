import AVFoundation
import Testing
@testable import PlumbAgents

@Suite struct PCMDownsamplerTests {
    /// A sine wave as the microphone would deliver it: 32-bit float, in buffers of `frames` frames.
    private func sine(hz: Double, sampleRate: Double, channels: AVAudioChannelCount, seconds: Double,
                      frames: Int, amplitude: Float = 0.5) throws -> (AVAudioFormat, [AVAudioPCMBuffer]) {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        var buffers: [AVAudioPCMBuffer] = []
        var position = 0
        let total = Int(sampleRate * seconds)
        while position < total {
            let count = min(frames, total - position)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let data = try #require(buffer.floatChannelData)
            for channel in 0..<Int(channels) {
                for frame in 0..<count {
                    data[channel][frame] = amplitude * Float(sin(2 * Double.pi * hz * Double(position + frame) / sampleRate))
                }
            }
            buffers.append(buffer)
            position += count
        }
        return (format, buffers)
    }

    /// The chunks as samples, read the way the voice service reads them: 16-bit little-endian.
    private func samples(in chunks: [Data]) -> [Int16] {
        chunks.flatMap { chunk in
            stride(from: 0, to: chunk.count - 1, by: 2).map { offset in
                Int16(bitPattern: UInt16(chunk[chunk.startIndex + offset]) | UInt16(chunk[chunk.startIndex + offset + 1]) << 8)
            }
        }
    }

    /// The frequency of a clean tone, from how often it crosses zero going up.
    private func frequency(of samples: [Int16], sampleRate: Double) -> Double {
        let risings = zip(samples, samples.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        return Double(risings) / (Double(samples.count) / sampleRate)
    }

    @Test func a48kHzSineComesOutAs16kHz16BitMonoAtTheSameFrequency() throws {
        let (format, buffers) = try sine(hz: 1000, sampleRate: 48_000, channels: 1, seconds: 1, frames: 4800)
        let downsampler = try #require(PCMDownsampler(inputFormat: format, chunkMs: 30))

        let chunks = buffers.flatMap(downsampler.feed)
        let output = samples(in: chunks)

        // 30 ms at 16 kHz is 480 samples of two bytes each, and every chunk is exactly that.
        #expect(downsampler.chunkBytes == 960)
        #expect(chunks.allSatisfy { $0.count == 960 })
        // One second in gives one second out, less the resampler's start-up and the unfinished last chunk.
        #expect(output.count > 15_000 && output.count <= 16_000)
        #expect(abs(frequency(of: output, sampleRate: 16_000) - 1000) < 15)
        // Half-scale float in is half-scale 16-bit out.
        let peak = Double(output.map { abs(Int($0)) }.max() ?? 0)
        #expect(abs(peak - 0.5 * 32_767) < 0.05 * 32_767)
    }

    @Test func stereoAt44kHzIsReducedToOneChannel() throws {
        let (format, buffers) = try sine(hz: 440, sampleRate: 44_100, channels: 2, seconds: 1, frames: 1024)
        let downsampler = try #require(PCMDownsampler(inputFormat: format, chunkMs: 20))

        let chunks = buffers.flatMap(downsampler.feed)
        let output = samples(in: chunks)

        #expect(chunks.allSatisfy { $0.count == 640 })
        #expect(output.count > 15_000 && output.count <= 16_000)
        #expect(abs(frequency(of: output, sampleRate: 16_000) - 440) < 10)
    }

    @Test func buffersShorterThanAChunkAreHeldUntilAChunkIsFull() throws {
        // 10 ms buffers into 30 ms chunks: nothing comes out until enough has gone in.
        let (format, buffers) = try sine(hz: 1000, sampleRate: 48_000, channels: 1, seconds: 0.3, frames: 480)
        let downsampler = try #require(PCMDownsampler(inputFormat: format, chunkMs: 30))

        #expect(downsampler.feed(buffers[0]).isEmpty)
        let chunks = buffers.dropFirst().flatMap(downsampler.feed)

        #expect(!chunks.isEmpty)
        #expect(chunks.count <= 10)
        #expect(chunks.allSatisfy { $0.count == 960 })
    }

    @Test func anEmptyBufferGivesNothing() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let empty = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        let downsampler = try #require(PCMDownsampler(inputFormat: format, chunkMs: 30))

        #expect(downsampler.feed(empty).isEmpty)
    }
}
