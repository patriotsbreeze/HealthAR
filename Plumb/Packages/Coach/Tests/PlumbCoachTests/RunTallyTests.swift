import PlumbContracts
import Testing
@testable import PlumbCoach

@Suite("Counting compressions")
struct RunTallyTests {
    private func compression(_ index: Int) -> SignalEvent {
        .compression(Compression(index: index, tTop: 0, tBottom: 0, depthMM: 55, intervalS: 0.55, lock: .locked))
    }

    @Test("Nothing has started until a compression is counted")
    func startsWithTheFirstCompression() {
        var tally = RunTally()
        let sawPause = tally.absorb(metrics: Metrics(count: 0), events: [])
        #expect(!sawPause)
        #expect(!tally.hasStarted)

        _ = tally.absorb(metrics: Metrics(count: 1), events: [])
        #expect(tally.hasStarted)
        #expect(tally.sincePause == 1)
    }

    @Test("A compression event counts even when Metrics has not caught up yet")
    func eventsMayRunAheadOfMetrics() {
        var tally = RunTally()
        _ = tally.absorb(metrics: Metrics(count: 0), events: [compression(1)])
        #expect(tally.hasStarted)
        #expect(tally.total == 1)
    }

    @Test("The same compression seen in an event and in Metrics is counted once")
    func noDoubleCounting() {
        var tally = RunTally()
        _ = tally.absorb(metrics: Metrics(count: 3), events: [compression(2), compression(3)])
        #expect(tally.total == 3)
    }

    @Test("While paused the run keeps restarting, so the count since the pause begins at the first stroke after it")
    func pauseRestartsTheRun() {
        var tally = RunTally()
        _ = tally.absorb(metrics: Metrics(count: 12), events: [])
        let sawPause = tally.absorb(metrics: Metrics(count: 12, isPaused: true, pauseSeconds: 2), events: [])
        #expect(sawPause)
        #expect(tally.sincePause == 0)

        _ = tally.absorb(metrics: Metrics(count: 15), events: [])
        #expect(tally.sincePause == 3)
        #expect(tally.total == 15)
    }

    @Test("A pause that began and ended between two looks splits the strokes before it from those after it")
    func eventOrderSplitsTheRun() {
        var tally = RunTally()
        _ = tally.absorb(metrics: Metrics(count: 13), events: [])
        let batch: [SignalEvent] = [
            compression(14),
            .pauseStarted(at: 7),
            .pauseEnded(at: 10, duration: 3),
            compression(15),
            compression(16),
        ]
        let sawPause = tally.absorb(metrics: Metrics(count: 16), events: batch)
        #expect(sawPause)
        #expect(tally.total == 16)
        #expect(tally.sincePause == 2)
    }
}
