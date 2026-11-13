import Foundation
import Testing
@testable import RescueAudio

/// A small seeded generator, so these signals are the same on every run.
private struct SeededRandom {
    var state: UInt64

    mutating func nextUnit() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(Int64(bitPattern: state) >> 40) / Float(1 << 23)
    }
}

private let sampleRate = 16_000

private func samples(milliseconds: Int) -> Int { sampleRate * milliseconds / 1000 }

private func int16(_ value: Float) -> Int16 {
    Int16(max(-1, min(1, value)) * 32767)
}

private func noise(milliseconds: Int, level: Float, seed: UInt64 = 7) -> [Int16] {
    var random = SeededRandom(state: seed)
    return (0..<samples(milliseconds: milliseconds)).map { _ in int16(random.nextUnit() * level) }
}

private func silence(milliseconds: Int) -> [Int16] {
    [Int16](repeating: 0, count: samples(milliseconds: milliseconds))
}

/// Noise shaped like syllables: 200 to 400 ms bursts around 4 per second, with soft gaps.
private func speechLike(milliseconds: Int, level: Float = 0.1, seed: UInt64 = 11) -> [Int16] {
    var random = SeededRandom(state: seed)
    var output: [Int16] = []
    while output.count < samples(milliseconds: milliseconds) {
        let burst = samples(milliseconds: 200 + Int(abs(random.nextUnit()) * 200))
        for index in 0..<burst {
            let envelope = sin(Float.pi * Float(index) / Float(burst))
            output.append(int16(random.nextUnit() * level * envelope.squareRoot()))
        }
        let gap = samples(milliseconds: 60 + Int(abs(random.nextUnit()) * 60))
        output.append(contentsOf: (0..<gap).map { _ in int16(random.nextUnit() * 0.001) })
    }
    return Array(output.prefix(samples(milliseconds: milliseconds)))
}

private func clickTrain(seconds: Int, gain: Float, reverbTau: Float? = nil, noiseLevel: Float = 0) -> [Int16] {
    var generator = ClickGenerator(sampleRate: sampleRate)
    let count = sampleRate * seconds
    var buffer = [Float](repeating: 0, count: count)
    buffer.withUnsafeMutableBufferPointer { generator.render(into: $0.baseAddress!, frameCount: count) }
    var random = SeededRandom(state: 3)
    var tail: Float = 0
    let decay = reverbTau.map { exp(-1 / ($0 * Float(sampleRate))) } ?? 0
    return buffer.map { value in
        // A rough room tail: decaying noise whose level follows the click.
        tail = max(abs(value) * gain, tail * decay)
        let reverb = reverbTau == nil ? 0 : tail * random.nextUnit()
        return int16(value * gain + reverb + random.nextUnit() * noiseLevel)
    }
}

/// Feeds audio in uneven pieces, like a real drain does.
private func run(_ vad: inout ClientVAD, _ input: [Int16]) -> [ClientVAD.Output] {
    var output: [ClientVAD.Output] = []
    var position = 0
    var size = 137
    while position < input.count {
        let end = min(position + size, input.count)
        output += vad.process(Array(input[position..<end]))
        position = end
        size = size % 400 + 89
    }
    return output
}

private func audio(in outputs: [ClientVAD.Output]) -> [[Int16]] {
    outputs.compactMap {
        if case let .audio(chunk) = $0 { chunk } else { nil }
    }
}

@Suite struct ClientVADTests {
    @Test func silenceNeverOpens() {
        var vad = ClientVAD()
        #expect(run(&vad, silence(milliseconds: 2000)).isEmpty)
    }

    @Test(arguments: [Float(1.0), 0.5, 0.1, 0.02])
    func clickTrainNeverOpens(gain: Float) {
        var vad = ClientVAD()
        #expect(run(&vad, clickTrain(seconds: 60, gain: gain)).isEmpty)
    }

    @Test func clickTrainOverRoomNoiseNeverOpens() {
        var vad = ClientVAD()
        #expect(run(&vad, clickTrain(seconds: 60, gain: 0.2, noiseLevel: 0.002)).isEmpty)
    }

    @Test func clickTrainWithAShortRoomTailNeverOpens() {
        // Clicks after echo cancellation, with a short tail. Real rooms need a device test.
        var vad = ClientVAD()
        #expect(run(&vad, clickTrain(seconds: 60, gain: 0.1, reverbTau: 0.015)).isEmpty)
    }

    @Test(arguments: [0, 16, 48, 80, 112, 159])
    func burstsUnder120MillisecondsNeverOpen(offset: Int) {
        var vad = ClientVAD()
        var input = silence(milliseconds: 200)
        input += [Int16](repeating: 0, count: offset)
        input += noise(milliseconds: 100, level: 0.5)
        input += silence(milliseconds: 500)
        #expect(run(&vad, input).isEmpty)
    }

    @Test func sustainedSoundOpensAfterAbout120Milliseconds() {
        var vad = ClientVAD()
        _ = run(&vad, silence(milliseconds: 200))
        #expect(run(&vad, noise(milliseconds: 100, level: 0.2)).isEmpty)
        let output = run(&vad, noise(milliseconds: 40, level: 0.2, seed: 9))
        #expect(output.first == .speechStarted)
        #expect(vad.isOpen)
    }

    @Test func speechLikeNoiseOpensAndLaterCloses() {
        var vad = ClientVAD()
        let output = run(&vad, silence(milliseconds: 300) + speechLike(milliseconds: 2000) + silence(milliseconds: 600))
        let events = output.filter { $0 == .speechStarted || $0 == .speechEnded }
        #expect(events == [.speechStarted, .speechEnded])
        #expect(output.first == .speechStarted)
        #expect(output.last == .speechEnded)
        #expect(!vad.isOpen)
    }

    @Test func quietSpeechOverRoomNoiseOpens() {
        var vad = ClientVAD()
        let room = noise(milliseconds: 500, level: 0.002)
        _ = run(&vad, room)
        let output = run(&vad, speechLike(milliseconds: 1000, level: 0.03))
        #expect(output.contains(.speechStarted))
    }

    @Test func holdsThroughShortPausesAndClosesAfterTheHangover() {
        var vad = ClientVAD()
        let open = run(&vad, silence(milliseconds: 100) + noise(milliseconds: 300, level: 0.2))
        #expect(open.contains(.speechStarted))
        // Under the 300 ms hangover: still the same utterance.
        #expect(!run(&vad, silence(milliseconds: 250)).contains(.speechEnded))
        _ = run(&vad, noise(milliseconds: 100, level: 0.2, seed: 21))
        #expect(!run(&vad, silence(milliseconds: 280)).contains(.speechEnded))
        #expect(run(&vad, silence(milliseconds: 40)).contains(.speechEnded))
    }

    @Test func uplinkCarriesThePreRollWithNoGapsOrRepeats() {
        var vad = ClientVAD()
        // Each sample is distinguishable, quiet before the loud part starts on a frame boundary.
        let lead: [Int16] = (0..<samples(milliseconds: 500)).map { Int16($0 % 40) - 20 }
        let loud: [Int16] = (0..<samples(milliseconds: 400)).map { index in
            let value = Int16(4000 + index % 8000)
            return index % 2 == 0 ? value : -value
        }
        let input = lead + loud
        let output = run(&vad, input)
        #expect(output.first == .speechStarted)

        // It opens 120 ms into the loud part, and the pre-roll reaches 300 ms back from there.
        let start = lead.count + samples(milliseconds: 120) - samples(milliseconds: 300)
        let sent = audio(in: output).flatMap { $0 }
        #expect(sent.count > samples(milliseconds: 300))
        #expect(sent == Array(input[start..<(start + sent.count)]))
    }

    @Test func everyChunkIsBetween20And40Milliseconds() {
        var vad = ClientVAD()
        let output = run(&vad, silence(milliseconds: 500) + speechLike(milliseconds: 3000) + silence(milliseconds: 500))
        let chunks = audio(in: output)
        #expect(!chunks.isEmpty)
        for chunk in chunks {
            #expect(chunk.count >= samples(milliseconds: 20))
            #expect(chunk.count <= samples(milliseconds: 40))
        }
    }

    @Test func noAudioIsSentWhileClosed() {
        var vad = ClientVAD()
        let output = run(&vad, silence(milliseconds: 300) + speechLike(milliseconds: 500) + silence(milliseconds: 1000))
        // Exactly one ended event, and nothing comes after it.
        #expect(output.last == .speechEnded)
        #expect(output.filter { $0 == .speechEnded }.count == 1)
        #expect(run(&vad, silence(milliseconds: 500)).isEmpty)
    }

    @Test func steadyLoudNoiseCannotHoldTheUplinkOpenForever() {
        var vad = ClientVAD()
        let output = run(&vad, noise(milliseconds: 40_000, level: 0.03))
        #expect(output.contains(.speechEnded))
        #expect(!vad.isOpen)
    }

    // The whole uplink path, as the 20 ms drain runs it: mic rate, ring, resampler, VAD.
    private func uplink(_ micSamples: [Float], micRate: Int) throws -> [ClientVAD.Output] {
        let ring = SPSCRingBuffer(capacity: 1 << 14)
        defer { ring.deallocate() }
        let resampler = try #require(MicResampler(inputSampleRate: Double(micRate)))
        var vad = ClientVAD()
        var output: [ClientVAD.Output] = []
        let piece = micRate / 50
        var position = 0
        while position < micSamples.count {
            let end = min(position + piece, micSamples.count)
            let slice = Array(micSamples[position..<end])
            #expect(ring.push(slice) == slice.count)
            position = end
            output += vad.process(resampler.drain(ring))
        }
        return output
    }

    @Test(arguments: [48_000, 24_000, 16_000])
    func clicksThroughTheWholeUplinkPathNeverOpen(micRate: Int) throws {
        var generator = ClickGenerator(sampleRate: micRate)
        var clicks = [Float](repeating: 0, count: micRate * 30)
        clicks.withUnsafeMutableBufferPointer { generator.render(into: $0.baseAddress!, frameCount: $0.count) }
        #expect(try uplink(clicks, micRate: micRate).isEmpty)
    }

    @Test(arguments: [48_000, 24_000, 16_000])
    func speechThroughTheWholeUplinkPathOpensAndCloses(micRate: Int) throws {
        var random = SeededRandom(state: 19)
        let rate = Float(micRate)
        var samples = [Float](repeating: 0, count: micRate / 2)
        for index in 0..<micRate * 2 {
            // Noise at syllable rate, so the resampler's low-pass doesn't remove all of it.
            let envelope = max(0, sin(2 * Float.pi * 3 * Float(index) / rate))
            samples.append(random.nextUnit() * 0.2 * envelope)
        }
        samples += [Float](repeating: 0, count: micRate)
        let output = try uplink(samples, micRate: micRate)
        #expect(output.first == .speechStarted)
        #expect(output.last == .speechEnded)
    }

    @Test func resetEndsSpeechAndForgetsThePreRoll() {
        var vad = ClientVAD()
        _ = run(&vad, noise(milliseconds: 300, level: 0.2))
        #expect(vad.isOpen)
        #expect(vad.reset() == [.speechEnded])
        #expect(vad.reset() == [])

        // Audio from before a reset, such as a dispatcher talking, must never be sent.
        let secret = [Int16](repeating: 1234, count: samples(milliseconds: 100))
        _ = vad.process(secret)
        _ = vad.reset()
        let fresh = noise(milliseconds: 200, level: 0.2, seed: 5)
        let output = run(&vad, fresh)
        #expect(output.first == .speechStarted)
        let sent = audio(in: output).flatMap { $0 }
        #expect(!sent.isEmpty)
        #expect(sent == Array(fresh.prefix(sent.count)))
    }
}
