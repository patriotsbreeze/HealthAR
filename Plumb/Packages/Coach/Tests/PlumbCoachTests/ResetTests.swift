import PlumbContracts
import Testing
@testable import PlumbCoach

@Suite("Reset and determinism")
struct ResetTests {
    /// A session that touches every piece of memory: faults, speech, a pause, a lost signal and praise.
    private func runBusySession(on bench: inout Bench) {
        bench.run(seconds: 12, .compressing(depthMM: 40, ratePerMin: 80))
        bench.run(seconds: 6, .paused())
        bench.run(seconds: 3, .paused(lock: .lost))
        bench.run(seconds: 12, .compressing(depthMM: 56))
        bench.run(seconds: 8, .compressing(depthMM: 56, ratePerMin: 140))
    }

    @Test("reset clears everything: memory is empty and the next session plays out exactly like a first one")
    func resetClearsEverything() {
        var used = Bench()
        runBusySession(on: &used)
        #expect(used.policy.memory != CuePolicy.Memory())

        used.policy.reset()
        #expect(used.policy.memory == CuePolicy.Memory())

        var afterReset = Bench(policy: used.policy)
        var fresh = Bench()
        runBusySession(on: &afterReset)
        runBusySession(on: &fresh)
        #expect(afterReset.frames == fresh.frames)
    }

    @Test("reset keeps the config and targets it was made with")
    func resetKeepsSettings() {
        var config = CuePolicy.Config()
        config.persistS = 1
        var targets = Targets.adult
        targets.depthMinMM = 45
        var policy = CuePolicy(config: config, targets: targets)
        policy.reset()
        #expect(policy.config == config)
        #expect(policy.targets == targets)
    }

    @Test("Nothing shown or said straight after a reset, even though the old session ended on a fault")
    func quietAfterReset() {
        var bench = Bench()
        #expect(bench.run(seconds: 10, .compressing(depthMM: 40)).last?.show == .pushHarder)
        bench.policy.reset()

        var policy = bench.policy
        let waiting = Metrics(t: 0, lock: .locked, count: 0, isPaused: true, pauseSeconds: 60)
        #expect(policy.update(metrics: waiting, events: [], now: 0) == CuePolicy.Decision())
    }

    @Test("The same inputs always give the same decisions")
    func deterministic() {
        var first = Bench()
        var second = Bench()
        runBusySession(on: &first)
        runBusySession(on: &second)
        #expect(first.frames == second.frames)
        #expect(first.frames.contains { $0.speak != nil })
    }

    @Test("Tunables are honoured: a shorter persistence window shows the fault sooner")
    func configIsHonoured() throws {
        var config = CuePolicy.Config()
        config.persistS = 1
        var bench = Bench(policy: CuePolicy(config: config))
        let frames = bench.run(seconds: 10, .compressing(depthMM: 40))
        let firstCompressionAt = try #require(frames.first { $0.count > 0 }).t
        #expect(frames.first { $0.show != nil }?.t == firstCompressionAt + 1)
    }
}
