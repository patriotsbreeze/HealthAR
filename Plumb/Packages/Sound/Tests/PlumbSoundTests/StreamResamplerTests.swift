import Foundation
import PlumbContracts
import Testing
@testable import PlumbSound

@Suite("Changing the sample rate of a stream")
struct StreamResamplerTests {
    let config = BeatEngine.Config()

    func resampler(from source: Double, to target: Double = 48_000) throws -> StreamResampler {
        try #require(StreamResampler(from: source, to: target, config: config))
    }

    /// A signal with no pattern to it, the same on every run.
    func noise(count: Int) -> [Float] {
        var generator = SplitMix64(seed: 7)
        return (0..<count).map { _ in Float(generator.nextUnit() - 0.5) }
    }

    @Test("However the stream is cut into pieces, the output is identical",
          arguments: [(16_000.0, 48_000.0), (22_050.0, 48_000.0), (24_000.0, 48_000.0),
                      (44_100.0, 48_000.0), (48_000.0, 24_000.0), (48_000.0, 44_100.0)])
    func piecesDoNotMatter(source: Double, target: Double) throws {
        let input = noise(count: 20_000)
        var whole = try resampler(from: source, to: target)
        let reference = whole.process(input) + whole.finish()

        var pieces = try resampler(from: source, to: target)
        var output: [Float] = []
        var start = 0
        for size in [1, 2, 3, 500, 17, 4_000, 1, 1, 9_000, 250, 20_000] where start < input.count {
            let end = min(input.count, start + size)
            output += pieces.process(Array(input[start..<end]))
            start = end
        }
        output += pieces.finish()

        #expect(output == reference)
        // The whole stream comes out as long, in seconds, as it went in.
        #expect(output.count == Int((20_000 * target / source).rounded(.up)))
    }

    @Test("A tone keeps its pitch and level and gains nothing else",
          arguments: [16_000.0, 22_050.0, 24_000.0, 44_100.0])
    func toneStaysPure(source: Double) throws {
        var resampler = try resampler(from: source)
        let input = sine(hertz: 700, seconds: 0.5, sampleRate: source)
        let output = resampler.process(input) + resampler.finish()
        let middle = output[2_400..<21_600]
        let level = toneAmplitude(in: middle, hertz: 700, sampleRate: 48_000)
        let meanSquare = middle.reduce(0) { $0 + Double($1 * $1) } / Double(middle.count)
        #expect(abs(level - 0.5) < 0.001)
        // All of the energy is the tone: under a millionth of it is anything else.
        #expect(abs(meanSquare - level * level / 2) < 0.000_000_2)
    }

    @Test("Output lines up in time with input: no delay is added")
    func noDelay() throws {
        var resampler = try resampler(from: 24_000)
        var input = [Float](repeating: 0, count: 2_000)
        input[1_000] = 1
        let output = resampler.process(input) + resampler.finish()
        let loudest = output.indices.max { abs(output[$0]) < abs(output[$1]) }
        #expect(loudest == 2_000)
    }

    @Test("A steady level stays exactly that level")
    func steadyLevel() throws {
        var resampler = try resampler(from: 22_050)
        let output = resampler.process([Float](repeating: 0.5, count: 4_000)) + resampler.finish()
        #expect(output[500..<8_000].allSatisfy { abs($0 - 0.5) < 0.000_01 })
    }

    @Test("Raising the rate adds no false high tone")
    func noImage() throws {
        var resampler = try resampler(from: 24_000)
        let output = resampler.process(sine(hertz: 5_000, seconds: 0.5, sampleRate: 24_000)) + resampler.finish()
        // Without filtering, a 5 kHz tone at 24 kHz would leave a copy at 19 kHz.
        #expect(toneAmplitude(in: output[2_400..<21_600], hertz: 19_000, sampleRate: 48_000) < 0.000_5)
        #expect(abs(toneAmplitude(in: output[2_400..<21_600], hertz: 5_000, sampleRate: 48_000) - 0.5) < 0.001)
    }

    @Test("Lowering the rate removes what the new rate cannot carry instead of folding it back")
    func noAliasing() throws {
        var resampler = try resampler(from: 48_000, to: 16_000)
        // 12 kHz cannot exist at 16 kHz; unfiltered it would come back as a false 4 kHz tone.
        let output = resampler.process(sine(hertz: 12_000, seconds: 0.5, sampleRate: 48_000)) + resampler.finish()
        #expect(output.count == 8_000)
        #expect(output[800..<7_200].allSatisfy { abs($0) < 0.001 })
    }

    @Test("Equal rates pass the audio through untouched")
    func sameRate() throws {
        var resampler = try resampler(from: 48_000)
        let input = noise(count: 1_000)
        #expect(resampler.process(input) == input)
        #expect(resampler.finish().isEmpty)
    }

    @Test("After finishing, the next stream starts clean")
    func finishStartsAfresh() throws {
        var reused = try resampler(from: 24_000)
        _ = reused.process(noise(count: 5_000))
        _ = reused.finish()
        var fresh = try resampler(from: 24_000)
        let input = sine(hertz: 440, seconds: 0.1, sampleRate: 24_000)
        #expect(reused.process(input) + reused.finish() == fresh.process(input) + fresh.finish())
    }

    @Test("Only a little of the stream waits inside for what follows")
    func littleIsHeldBack() throws {
        var resampler = try resampler(from: 24_000)
        let made = resampler.process([Float](repeating: 0.25, count: 2_400)).count
        // 2400 samples become 4800; all but the last millisecond or so can be made at once.
        #expect(made > 4_800 - 48 && made < 4_800)
        #expect(made + resampler.finish().count == 4_800)
    }

    @Test("Rates that are not usable numbers are refused")
    func unusableRates() {
        for rate in [0, -1, 0.4, Double.nan, Double.infinity] {
            #expect(StreamResampler(from: rate, to: 48_000, config: config) == nil)
            #expect(StreamResampler(from: 24_000, to: rate, config: config) == nil)
        }
    }
}
