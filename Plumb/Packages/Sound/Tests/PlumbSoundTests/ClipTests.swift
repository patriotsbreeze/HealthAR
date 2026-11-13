import AVFoundation
import Testing
@testable import PlumbSound

@Suite("Clips: plain audio in and out of buffers")
struct ClipTests {
    @Test("16-bit little-endian bytes become samples; an odd last byte is dropped")
    func pcm16() {
        let bytes = Data([0x00, 0x40, 0x00, 0x80, 0xFF, 0x7F, 0x00, 0x00, 0x12])
        let clip = MonoClip(pcm16: bytes, sampleRate: 24_000)
        #expect(clip.samples == [0.5, -1, 32_767.0 / 32_768, 0])
        #expect(clip.sampleRate == 24_000)
        #expect(MonoClip(pcm16: Data(), sampleRate: 24_000).samples.isEmpty)
    }

    @Test("Bytes that do not start on an even address are still read correctly")
    func pcm16Unaligned() {
        let padded = Data([0xAA, 0x00, 0x40, 0x00, 0xC0])
        let clip = MonoClip(pcm16: padded.dropFirst(), sampleRate: 24_000)
        #expect(clip.samples == [0.5, -0.5])
    }

    @Test("Duration and peak")
    func measures() {
        let clip = MonoClip(samples: [0, 0.25, -0.75, 0.5], sampleRate: 4)
        #expect(clip.duration == 1)
        #expect(clip.peak == 0.75)
        #expect(MonoClip(samples: [], sampleRate: 48_000).peak == 0)
        #expect(MonoClip(samples: [1], sampleRate: 0).duration == 0)
    }

    @Test("Quiet ends are trimmed, keeping a little padding")
    func trimming() {
        let quiet = [Float](repeating: 0.000_1, count: 1_000)
        let loud = [Float](repeating: 0.5, count: 500)
        let clip = MonoClip(samples: quiet + loud + quiet, sampleRate: 1_000)
        let trimmed = clip.trimmingQuietEnds(floor: 0.01, padSeconds: 0.02)
        // 20 ms at 1000 Hz is 20 samples of padding each side.
        #expect(trimmed.samples.count == 540)
        #expect(trimmed.samples[19] == 0.000_1 && trimmed.samples[20] == 0.5)
        // Nothing to trim, and nothing audible at all: both come back unchanged.
        #expect(MonoClip(samples: loud, sampleRate: 1_000).trimmingQuietEnds(floor: 0.01, padSeconds: 0.02).samples == loud)
        let silent = MonoClip(samples: [0, 0, 0], sampleRate: 1_000)
        #expect(silent.trimmingQuietEnds(floor: 0.01, padSeconds: 0.02) == silent)
    }

    @Test("Scaling sets the peak and leaves silence alone")
    func scaling() {
        let clip = MonoClip(samples: [0.1, -0.2, 0.05], sampleRate: 48_000).scaled(toPeak: 0.6)
        #expect(abs(clip.peak - 0.6) < 0.000_001)
        #expect(abs(clip.samples[0] - 0.3) < 0.000_001)
        let silent = MonoClip(samples: [0, 0], sampleRate: 48_000)
        #expect(silent.scaled(toPeak: 0.6) == silent)
    }

    @Test("Resampling keeps length in seconds, level and pitch")
    func resampling() throws {
        let config = BeatEngine.Config()
        let original = MonoClip(samples: sine(hertz: 1_000, seconds: 0.5, sampleRate: 22_050), sampleRate: 22_050)
        let resampled = try #require(original.resampled(to: 48_000, config: config))
        #expect(resampled.sampleRate == 48_000)
        #expect(resampled.samples.count == 24_000)
        #expect(abs(toneAmplitude(in: resampled.samples, hertz: 1_000, sampleRate: 48_000) - 0.5) < 0.005)
        #expect(original.resampled(to: 22_050, config: config) == original)
        #expect(MonoClip(samples: [1], sampleRate: .nan).resampled(to: 48_000, config: config) == nil)
        #expect(MonoClip(samples: [1], sampleRate: 0).resampled(to: 48_000, config: config) == nil)
    }

    @Test("A clip survives the trip into an engine buffer and back")
    func bufferRoundTrip() throws {
        let clip = MonoClip(samples: [0.1, -0.2, 0.3, -0.4], sampleRate: 48_000)
        let buffer = try #require(clip.makeBuffer())
        #expect(buffer.frameLength == 4)
        #expect(buffer.format.channelCount == 1)
        #expect(MonoClip(firstChannelOf: buffer) == clip)
        #expect(MonoClip(samples: [], sampleRate: 48_000).makeBuffer() == nil)
    }

    @Test("Buffers of 16-bit and interleaved audio are read as their first channel")
    func otherBufferTypes() throws {
        let sixteenBit = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 22_050,
                                                    channels: 2, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: sixteenBit, frameCapacity: 3))
        buffer.frameLength = 3
        let data = try #require(buffer.int16ChannelData)
        // Left, right, left, right, left, right.
        for (index, value) in [16_384, 1, -16_384, 2, 8_192, 3].enumerated() {
            data[0][index] = Int16(value)
        }
        let clip = try #require(MonoClip(firstChannelOf: buffer))
        #expect(clip.samples == [0.5, -0.5, 0.25])
        #expect(clip.sampleRate == 22_050)
    }
}
