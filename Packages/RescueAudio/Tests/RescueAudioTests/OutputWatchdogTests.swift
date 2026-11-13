import Testing
@testable import RescueAudio
@testable import RescueCore

@Suite struct OutputWatchdogTests {
    @Test func callbacksConfirmTheEngineOnce() {
        var watchdog = OutputWatchdog()
        watchdog.engineStarted(at: 0)
        #expect(watchdog.check(renderCount: 0, mode: .playbackOnly, at: 0.5) == .nothingToDo)
        #expect(watchdog.check(renderCount: 1, mode: .playbackOnly, at: 0.6) == .confirmed)
        #expect(watchdog.check(renderCount: 2, mode: .playbackOnly, at: 0.7) == .nothingToDo)
    }

    @Test func silentPlaybackKeepsRebuildingAndNeverGivesUp() {
        var watchdog = OutputWatchdog()
        var now = 0.0
        watchdog.engineStarted(at: now)
        for _ in 0..<10 {
            now += 1.1
            #expect(watchdog.check(renderCount: 0, mode: .playbackOnly, at: now) == .rebuild(giveUpOnMic: false))
            watchdog.engineStarted(at: now)
        }
    }

    /// The metronome must not wait on voice processing forever. This is the case with no other exit:
    /// `engine.start()` succeeds, no callback ever arrives, and no notification says so.
    @Test func aSilentEngineWithTheMicGivesUpOnTheMicOnTheSecondTry() {
        var watchdog = OutputWatchdog()
        watchdog.engineStarted(at: 0)
        #expect(watchdog.check(renderCount: 0, mode: .full, at: 2.1) == .rebuild(giveUpOnMic: false))
        watchdog.engineStarted(at: 2.1)
        #expect(watchdog.check(renderCount: 0, mode: .full, at: 4.2) == .rebuild(giveUpOnMic: true))
    }

    @Test func voiceProcessingGetsLongerForItsFirstBuffer() {
        var watchdog = OutputWatchdog()
        watchdog.engineStarted(at: 0)
        #expect(watchdog.check(renderCount: 0, mode: .full, at: 1.5) == .nothingToDo)
        #expect(watchdog.check(renderCount: 1, mode: .full, at: 1.9) == .confirmed)
        // Once running, it's held to the normal limit.
        #expect(watchdog.check(renderCount: 1, mode: .full, at: 2.8) == .nothingToDo)
        #expect(watchdog.check(renderCount: 1, mode: .full, at: 3.0) == .rebuild(giveUpOnMic: false))
    }

    @Test func aConfirmedEngineClearsTheCount() {
        var watchdog = OutputWatchdog()
        watchdog.engineStarted(at: 0)
        #expect(watchdog.check(renderCount: 0, mode: .full, at: 2.1) == .rebuild(giveUpOnMic: false))
        watchdog.engineStarted(at: 2.1)
        #expect(watchdog.check(renderCount: 1, mode: .full, at: 2.5) == .confirmed)
        #expect(watchdog.check(renderCount: 1, mode: .full, at: 3.6) == .rebuild(giveUpOnMic: false))
        watchdog.engineStarted(at: 3.6)
        #expect(watchdog.check(renderCount: 2, mode: .full, at: 3.9) == .confirmed)
    }

    @Test func aMicRetryThatIsAlsoSilentGivesUpStraightAway() {
        var watchdog = OutputWatchdog()
        watchdog.engineStarted(at: 0)
        _ = watchdog.check(renderCount: 0, mode: .full, at: 2.1)
        watchdog.engineStarted(at: 2.1)
        #expect(watchdog.check(renderCount: 0, mode: .full, at: 4.2) == .rebuild(giveUpOnMic: true))
        watchdog.engineStarted(at: 4.2)
        // Playback runs for a while, without touching the count.
        #expect(watchdog.check(renderCount: 1, mode: .playbackOnly, at: 4.3) == .confirmed)
        watchdog.engineStarted(at: 7.2)
        #expect(watchdog.check(renderCount: 1, mode: .full, at: 9.3) == .rebuild(giveUpOnMic: true))
    }

    @Test func noEngineAtAllKeepsTrying() {
        var watchdog = OutputWatchdog()
        watchdog.engineStarted(at: 0)
        #expect(watchdog.check(renderCount: 0, mode: nil, at: 1.1) == .rebuild(giveUpOnMic: false))
    }

    @Test func anInterruptionNeedsProvingAgain() {
        var watchdog = OutputWatchdog()
        watchdog.engineStarted(at: 0)
        #expect(watchdog.check(renderCount: 1, mode: .playbackOnly, at: 0.1) == .confirmed)
        watchdog.outputInterrupted()
        #expect(watchdog.check(renderCount: 2, mode: .playbackOnly, at: 0.2) == .confirmed)
    }
}
