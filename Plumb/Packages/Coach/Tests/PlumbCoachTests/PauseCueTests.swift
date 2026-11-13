import PlumbContracts
import Testing
@testable import PlumbCoach

@Suite("Push now")
struct PauseCueTests {
    /// A bench with ten seconds of good compressions behind it, so a pause means something.
    private func benchAfterGoodStart() -> Bench {
        var bench = Bench()
        bench.run(seconds: 10, .compressing())
        return bench
    }

    @Test("Paused: shown at once, said when the pause reaches the threshold, and again on the repeat interval")
    func shownAtOnceThenSaidOnSchedule() {
        var bench = benchAfterGoodStart()
        let pauseSeenAt = bench.now + Bench.tick
        let paused = bench.run(seconds: 14, .paused())

        #expect(paused.allSatisfy { $0.show == .pushNow })
        #expect(paused.first?.speak == nil)
        // The made-up analyzer reports the pause when it is already 1.5 s old, so 3 s arrives 1.5 s later.
        let saidAt = pauseSeenAt + (3 - Bench.pauseNoticedAfterS)
        #expect(paused.utterances == [
            Utterance(saidAt, .pushNow),
            Utterance(saidAt + 5, .pushNow),
            Utterance(saidAt + 10, .pushNow),
        ])
    }

    @Test("A pause is shown whenever there is a signal, trusted for depth or not",
          arguments: [LockState.locked, .estimating, .rateOnly])
    func shownWithAnyUsableSignal(lock: LockState) {
        var bench = benchAfterGoodStart()
        #expect(bench.step(.paused(lock: lock)).show == .pushNow)
    }

    @Test("A pause reported while the signal is lost shows nothing and says nothing")
    func pauseUnderLostSignal() {
        var bench = benchAfterGoodStart()
        let paused = bench.run(seconds: 20, .paused(lock: .lost))
        #expect(paused.isSilentAndBlank)
    }

    @Test("Signal lost during a pause: the cue goes quiet, and returns only once the signal has settled")
    func signalLostMidPause() {
        var bench = benchAfterGoodStart()
        let seen = bench.run(seconds: 2, .paused())
        #expect(seen.utterances.count == 1)

        let lost = bench.run(seconds: 12, .paused(lock: .lost))
        #expect(lost.isSilentAndBlank)

        let returnedAt = bench.now + Bench.tick
        let back = bench.run(seconds: 3, .paused())
        #expect(back.filter { $0.t < returnedAt + 1 }.isSilentAndBlank)
        #expect(back.filter { $0.t >= returnedAt + 1 }.allSatisfy { $0.show == .pushNow })
        #expect(back.utterances == [Utterance(returnedAt + 1, .pushNow)])
    }

    @Test("A signal loss too short to be seen on a look still makes the pause wait for the signal to settle")
    func signalBlinkSeenOnlyInEvents() {
        var bench = benchAfterGoodStart()
        let blink: [SignalEvent] = [.lockChanged(.lost, at: bench.now), .lockChanged(.locked, at: bench.now)]
        let blinkAt = bench.now + Bench.tick
        #expect(bench.step(.paused(), events: blink).show == nil)

        let after = bench.run(seconds: 2, .paused())
        #expect(after.filter { $0.t < blinkAt + 1 }.allSatisfy { $0.show == nil })
        #expect(after.filter { $0.t >= blinkAt + 1 }.allSatisfy { $0.show == .pushNow })
    }

    @Test("Each pause starts its own count towards being said")
    func secondPauseIsSaidOnItsOwnSchedule() {
        var bench = benchAfterGoodStart()
        #expect(bench.run(seconds: 2, .paused()).utterances.count == 1)
        bench.run(seconds: 1, .compressing())

        let secondSeenAt = bench.now + Bench.tick
        let second = bench.run(seconds: 2, .paused())
        #expect(second.utterances == [Utterance(secondSeenAt + 1.5, .pushNow)])
    }

    @Test("The command clears as soon as compressions resume")
    func clearsOnResume() {
        var bench = benchAfterGoodStart()
        bench.run(seconds: 4, .paused())
        #expect(bench.step(.compressing()).show == nil)
    }
}
