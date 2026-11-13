import PlumbContracts
import Testing
@testable import PlumbCoach

@Suite("Sparse voice")
struct SpeechBudgetTests {
    private let config = CuePolicy.Config()

    /// The most corrections the gaps can allow in a stretch: one at the start, then one per gap.
    private func ceiling(seconds: Double, gap: Double) -> Int {
        Int(seconds / gap) + 1
    }

    @Test("Sixty seconds of persistently shallow, slow compressions: spoken corrections stay within what the gaps allow")
    func persistentlyShallowAndSlow() {
        var bench = Bench()
        let frames = bench.run(seconds: 60, .compressing(depthMM: 40, ratePerMin: 80))
        let correctives = frames.spokenCorrectives

        #expect(!correctives.isEmpty)
        #expect(correctives.count <= ceiling(seconds: 60, gap: config.correctiveGapS))
        for cue in Cue.allCases {
            let said = correctives.filter { $0.cue == cue }.count
            #expect(said <= ceiling(seconds: 60, gap: config.sameCueGapS))
        }
        // Only the fault on screen is ever said, so the lower-priority one stays silent throughout.
        #expect(correctives.allSatisfy { $0.cue == .pushHarder })
        #expect(correctives.count == 5)
        expectHouseRules(frames, config: config)
    }

    @Test("Faults that come and go as fast as the rules allow still cannot make the voice busy")
    func churningFaults() {
        var bench = Bench()
        // Slow throughout; depth swings between clearly shallow and clearly fine every four seconds,
        // so the screen alternates between two corrections and both become eligible to be said.
        let frames = bench.run(seconds: 60) { tick in
            let shallowPhase = (tick / 32).isMultiple(of: 2)
            return .compressing(depthMM: shallowPhase ? 40 : 56, ratePerMin: 80)
        }
        let correctives = frames.spokenCorrectives

        #expect(Set(correctives.map(\.cue)) == [.pushHarder, .faster])
        #expect(correctives.count <= ceiling(seconds: 60, gap: config.correctiveGapS))
        expectHouseRules(frames, config: config)
    }

    @Test("A correction is shown as soon as it is believed, but waits out the gap after praise before it is said")
    func correctionWaitsAfterPraise() throws {
        var bench = Bench()
        let praised = bench.run(.compressing(), until: { $0.speak == .good })
        let praisedAt = try #require(praised).t

        let shallow = bench.run(seconds: 10, .compressing(depthMM: 40))
        let firstShallowLookAt = praisedAt + Bench.tick
        #expect(shallow.first { $0.show == .pushHarder }?.t == firstShallowLookAt + 2.5)
        #expect(shallow.utterances == [Utterance(praisedAt + 6, .pushHarder)])
    }

    @Test("A correction also waits out the gap after push now, though push now itself never waits")
    func correctionWaitsAfterPushNow() throws {
        var bench = Bench()
        bench.run(seconds: 10, .compressing())
        let prompted = bench.run(.paused(), until: { $0.speak == .pushNow })
        let pushNowAt = try #require(prompted).t

        let shallow = bench.run(seconds: 10, .compressing(depthMM: 40))
        let firstShallowLookAt = pushNowAt + Bench.tick
        #expect(shallow.first { $0.show == .pushHarder }?.t == firstShallowLookAt + 2.5)
        #expect(shallow.utterances == [Utterance(pushNowAt + 6, .pushHarder)])
    }

    @Test("Push now is said on its own schedule even straight after another correction")
    func pushNowIgnoresTheCorrectiveGap() throws {
        var bench = Bench()
        let corrected = bench.run(.compressing(depthMM: 40), until: { $0.speak == .pushHarder })
        let harderAt = try #require(corrected).t

        let paused = bench.run(seconds: 3, .paused(depthMM: 40))
        let said = try #require(paused.utterances.first)
        #expect(said.cue == .pushNow)
        #expect(said.t - harderAt < config.correctiveGapS)
    }

    @Test("At most one cue is said per look, and almost every look says nothing")
    func speechIsRare() {
        var bench = Bench()
        bench.run(seconds: 20, .compressing(depthMM: 40, ratePerMin: 80))
        bench.run(seconds: 8, .paused())
        bench.run(seconds: 30, .compressing())
        let spokenLooks = bench.frames.filter { $0.speak != nil }.count
        #expect(spokenLooks > 0)
        #expect(Double(spokenLooks) / Double(bench.frames.count) < 0.03)
        expectHouseRules(bench.frames, config: config)
    }
}
