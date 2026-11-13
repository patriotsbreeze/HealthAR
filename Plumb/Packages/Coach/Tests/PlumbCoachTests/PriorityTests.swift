import PlumbContracts
import Testing
@testable import PlumbCoach

@Suite("One thing at a time")
struct PriorityTests {
    private let shallowAndSlow = Scene.compressing(depthMM: 40, ratePerMin: 80)

    @Test("Both shallow and slow: push harder wins; once depth is fixed, faster follows after the corrective gap")
    func depthBeforeRate() throws {
        var bench = Bench()
        let firstCompressionAt = try #require(bench.run(seconds: 2, shallowAndSlow).first { $0.count > 0 }).t
        let harderAt = firstCompressionAt + 2.5

        // Long enough for the rate fault to be believed too, so only priority is keeping it off screen.
        while bench.now < harderAt + 5 { bench.step(shallowAndSlow) }
        #expect(bench.frames.allSatisfy { $0.show == nil || $0.show == .pushHarder })
        #expect(bench.frames.utterances == [Utterance(harderAt, .pushHarder)])

        let depthFixed = bench.run(seconds: 8, .compressing(depthMM: 56, ratePerMin: 80))
        #expect(depthFixed.allSatisfy { $0.show == .faster })
        #expect(depthFixed.utterances == [Utterance(harderAt + 6, .faster)])
        expectHouseRules(bench.frames)
    }

    @Test("A pause outranks every other fault")
    func pauseBeforeEverything() {
        var bench = Bench()
        #expect(bench.run(seconds: 10, shallowAndSlow).last?.show == .pushHarder)
        let paused = bench.run(seconds: 3, .paused(depthMM: 40, ratePerMin: 80))
        #expect(paused.allSatisfy { $0.show == .pushNow })
        #expect(paused.utterances.allSatisfy { $0.cue == .pushNow })
    }

    @Test("Shallow and too fast: push harder wins over slower as well")
    func depthBeforeSlower() {
        var bench = Bench()
        let frames = bench.run(seconds: 20, .compressing(depthMM: 40, ratePerMin: 140))
        #expect(frames.allSatisfy { $0.show == nil || $0.show == .pushHarder })
        #expect(frames.utterances.allSatisfy { $0.cue == .pushHarder })
    }
}
