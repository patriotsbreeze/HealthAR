import AVFAudio
import Testing
@testable import RescueAudio

/// Runs the real source nodes through a real `AVAudioEngine` mixer, faster than real time and with
/// no audio hardware. It can't check the device's speaker or clock.
@Suite struct GraphRenderTests {
    private func render(core: RenderCore, outputRate: Double, seconds: Double) throws -> [Float] {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1))
        let block: AVAudioFrameCount = 512
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: block)
        #expect(core.attachOutputs(to: engine))
        try engine.start()
        defer { engine.stop() }

        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block))
        var output: [Float] = []
        let total = Int(outputRate * seconds)
        output.reserveCapacity(total)
        while output.count < total {
            let status = try engine.renderOffline(block, to: buffer)
            #expect(status == .success)
            let channel = try #require(buffer.floatChannelData?[0])
            output.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        return output
    }

    @Test(arguments: [Double(44_100), 48_000, 24_000, 16_000])
    func beatStaysOnTheGridThroughTheMixerAtEveryHardwareRate(outputRate: Double) throws {
        let core = RenderCore()
        defer { core.deallocate() }
        core.setMetronome(on: true)
        let output = try render(core: core, outputRate: outputRate, seconds: 120)

        // A beat is the first loud sample after a quiet stretch longer than the soft click's delay.
        var onsets: [Int] = []
        let quiet = Int(outputRate * 0.2)
        var sinceLoud = quiet
        for (index, sample) in output.enumerated() {
            if abs(sample) > 0.05 {
                if sinceLoud >= quiet { onsets.append(index) }
                sinceLoud = 0
            } else {
                sinceLoud += 1
            }
        }

        // 220 beats in 120 s. Rendering stops at a block edge, which can catch the next one.
        #expect(onsets.count >= 220)
        let ideal = 60.0 / 110 * outputRate
        for (index, onset) in onsets.enumerated() {
            // Relative to the first beat, since the mixer's resampler adds a fixed delay.
            #expect(abs(Double(onset - onsets[0]) - Double(index) * ideal) <= 2)
        }
    }

    @Test(arguments: [Double(44_100), 48_000, 16_000])
    func voiceKeepsItsPitchAndLengthThroughTheMixer(outputRate: Double) throws {
        let core = RenderCore()
        defer { core.deallocate() }
        let rate = Float(RenderCore.voiceSampleRate)
        let tone = (0..<RenderCore.voiceSampleRate).map { 0.5 * sin(2 * Float.pi * 440 * Float($0) / rate) }
        #expect(core.phraseRing.push(tone) == tone.count)

        let output = try render(core: core, outputRate: outputRate, seconds: 1.5)

        let audible = output.indices.filter { abs(output[$0]) > 0.01 }
        let first = try #require(audible.first)
        let last = try #require(audible.last)
        #expect(abs(Double(last - first) / outputRate - 1) < 0.01)

        let middle = output[(first + 100)..<(last - 100)]
        let crossings = zip(middle, middle.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        #expect(abs(Double(crossings) / (Double(middle.count) / outputRate) - 440) < 3)
        #expect(core.phraseRing.totalRead == tone.count)
    }

    @Test func localPhraseOverModelAudioThroughTheMixer() throws {
        let core = RenderCore()
        defer { core.deallocate() }
        // Loud model audio, then a flush and a much quieter phrase. Only the phrase may be heard.
        core.modelRing.push([Float](repeating: 0.9, count: 24_000))
        core.modelRing.flush()
        core.phraseRing.push([Float](repeating: 0.1, count: 12_000))
        let output = try render(core: core, outputRate: 48_000, seconds: 1)
        #expect((output.map(abs).max() ?? 1) < 0.2)
        #expect((output.map(abs).max() ?? 0) > 0.05)
    }
}
