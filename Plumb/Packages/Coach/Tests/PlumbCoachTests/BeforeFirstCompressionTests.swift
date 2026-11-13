import PlumbContracts
import Testing
@testable import PlumbCoach

@Suite("Before the first compression")
struct BeforeFirstCompressionTests {
    @Test("Nothing is shown or spoken before any compression, however long the wait",
          arguments: LockState.allCases)
    func silentWhileWaiting(lock: LockState) {
        var bench = Bench()
        let frames = bench.run(seconds: 600, Scene(cadence: 0, ratePerMin: nil, depthMM: nil, lock: lock))
        #expect(frames.isSilentAndBlank)
    }

    @Test("Readings that would earn every cue are still ignored until compressions have begun",
          arguments: LockState.allCases)
    func silentEvenWithHostileReadings(lock: LockState) {
        var bench = Bench()
        // A reported pause, a crawl of a rate and a tiny depth: each would be a fault later in a session.
        let hostile = Scene(cadence: 0, ratePerMin: 40, depthMM: 10, lock: lock, isPaused: true)
        let frames = bench.run(seconds: 600, hostile)
        #expect(frames.isSilentAndBlank)
    }
}
