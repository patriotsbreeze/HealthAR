import AVFAudio
import Foundation
import Testing
@testable import RescueAudio

@Suite struct PCMConversionTests {
    // MARK: - PCM16

    @Test func decodesLittleEndianSamples() {
        var decoder = PCM16Decoder()
        let output = decoder.decode(Data([0x00, 0x40, 0x00, 0xC0, 0x00, 0x00, 0xFF, 0x7F, 0x00, 0x80]))
        #expect(output == [0.5, -0.5, 0, 32767.0 / 32768, -1])
    }

    @Test func holdsAStrayByteUntilTheNextChunk() {
        var decoder = PCM16Decoder()
        #expect(decoder.decode(Data([0x00, 0x40, 0x00])) == [0.5])
        #expect(decoder.decode(Data([0xC0, 0x00, 0x40])) == [-0.5, 0.5])
        #expect(decoder.decode(Data()) == [])
    }

    @Test func resetForgetsTheStrayByte() {
        var decoder = PCM16Decoder()
        _ = decoder.decode(Data([0x11]))
        decoder.reset()
        #expect(decoder.decode(Data([0x00, 0x40])) == [0.5])
    }

    @Test func handlesDataThatIsASliceOfALargerBuffer() {
        var decoder = PCM16Decoder()
        let whole = Data([0xFF, 0xFF, 0x00, 0x40])
        #expect(decoder.decode(whole[2...]) == [0.5])
    }

    @Test func encodesLittleEndian() {
        #expect(PCM16.data(from: [0x4000, -1]) == Data([0x00, 0x40, 0xFF, 0xFF]))
    }

    // MARK: - Clips

    private func writeWAV(sampleRate: Double, channels: AVAudioChannelCount, seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = try #require(buffer.floatChannelData?[channel])
            for frame in 0..<Int(frames) {
                data[frame] = 0.5 * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate))
            }
        }
        try file.write(from: buffer)
        return url
    }

    @Test(arguments: [(Double(22_050), AVAudioChannelCount(1)), (24_000, 1), (44_100, 2), (48_000, 1)])
    func decodesClipsToTwentyFourKilohertzMono(sampleRate: Double, channels: AVAudioChannelCount) throws {
        let url = try writeWAV(sampleRate: sampleRate, channels: channels, seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try decodeClip(at: url)

        #expect(abs(samples.count - RenderCore.voiceSampleRate) < 100)
        // Pitch survives: about 440 upward zero crossings per second.
        let middle = samples[1000..<(samples.count - 1000)]
        let crossings = zip(middle, middle.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        let expected = 440.0 * Double(middle.count) / Double(RenderCore.voiceSampleRate)
        #expect(abs(Double(crossings) - expected) < 5)
        #expect((middle.max() ?? 0) > 0.2)
    }

    @Test func aMissingOrCorruptClipThrowsInsteadOfPlayingNothing() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/phrase.wav")
        #expect(throws: (any Error).self) { try decodeClip(at: missing) }

        let corrupt = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data("not audio".utf8).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }
        #expect(throws: (any Error).self) { try decodeClip(at: corrupt) }
    }

    // MARK: - Mic

    @Test(arguments: [Double(48_000), 44_100, 24_000, 16_000])
    func micResamplesToSixteenKilohertzAcrossSmallDrains(inputRate: Double) throws {
        let resampler = try #require(MicResampler(inputSampleRate: inputRate))
        let ring = SPSCRingBuffer(capacity: 1 << 16)
        defer { ring.deallocate() }

        // Two seconds fed in 20 ms pieces, as the drain sees it.
        var output: [Int16] = []
        let pieceFrames = Int(inputRate / 50)
        var phase = 0
        for _ in 0..<100 {
            let piece = (0..<pieceFrames).map { index in
                0.5 * sin(2 * Float.pi * 440 * Float(phase + index) / Float(inputRate))
            }
            phase += pieceFrames
            ring.push(piece)
            output += resampler.drain(ring)
        }

        #expect(abs(output.count - 32_000) < 200)
        let middle = output[2000..<(output.count - 2000)]
        let crossings = zip(middle, middle.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        let expected = 440.0 * Double(middle.count) / 16_000
        #expect(abs(Double(crossings) - expected) < 5)
        #expect((middle.max() ?? 0) > 8000)
    }

    @Test func micDrainOfAnEmptyRingReturnsNothing() throws {
        let resampler = try #require(MicResampler(inputSampleRate: 48_000))
        let ring = SPSCRingBuffer(capacity: 1024)
        defer { ring.deallocate() }
        #expect(resampler.drain(ring).isEmpty)
    }

    @Test func invalidMicRateIsRefused() {
        #expect(MicResampler(inputSampleRate: 0) == nil)
    }
}
