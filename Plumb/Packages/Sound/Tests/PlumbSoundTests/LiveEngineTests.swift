import Foundation
import PlumbContracts
import Testing
@testable import PlumbSound

/// The one suite that opens the Mac's real output, so it runs only when asked for:
///
///     PLUMB_LIVE_AUDIO=1 swift test --filter LiveEngineTests
///
/// Everything else is tested offline and needs no hardware. The beat is silenced before the
/// engine starts, so this plays nothing but digital silence.
@Suite("The engine on a real output",
       .enabled(if: ProcessInfo.processInfo.environment["PLUMB_LIVE_AUDIO"] != nil,
                "Set PLUMB_LIVE_AUDIO=1 to run against real audio hardware."))
struct LiveEngineTests {
    @Test("A silenced engine starts, keeps time against the real clock, and stops")
    func runsSilently() throws {
        let engine = BeatEngine(targets: .adult, config: .init(), speaker: FailingSpeaker(failure: .noAudio))
        engine.setBeatAudible(false)
        try engine.start()
        #expect(engine.isRunning)

        // The hardware takes a moment to begin asking for sound. Until it does the phase is 0.
        let clock = ContinuousClock()
        let started = clock.now
        while engine.beatPhase == 0, clock.now - started < .seconds(10) {
            Thread.sleep(forTimeInterval: 0.001)
        }
        print("The audio thread began after \(clock.now - started).")

        // Read the phase about every millisecond for 100 ms, noting the time of each reading.
        var readings: [(seconds: Double, phase: Double)] = []
        let began = clock.now
        for _ in 0..<100 {
            let elapsed = clock.now - began
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
            readings.append((seconds, engine.beatPhase))
            Thread.sleep(forTimeInterval: 0.001)
        }
        #expect(readings.allSatisfy { $0.phase >= 0 && $0.phase < 1 })

        // The phase must follow real time: at 110 a minute, a beat lasts 60/110 s.
        let beatSeconds = 60.0 / 110
        let errors = zip(readings.dropFirst(), readings).map { later, earlier in
            let expected = (later.seconds - earlier.seconds) / beatSeconds
            let advance = (later.phase - earlier.phase + 1).truncatingRemainder(dividingBy: 1)
            return abs(advance - expected)
        }
        let typicalError = errors.sorted()[errors.count / 2]
        #expect(typicalError < 0.000_5, "phase strays from the clock by \(typicalError) of a beat per reading")

        // It moves between the audio system's blocks, not once per block: a 512-sample block
        // lasts 10.7 ms, so stepping per block would give about 10 different values in 100 ms.
        let distinct = Set(readings.map(\.phase)).count
        #expect(distinct > 50, "only \(distinct) different phases in 100 readings")
        print("Phase readings: \(distinct) distinct of 100, typical error \(typicalError) of a beat.")

        engine.stop()
        #expect(!engine.isRunning)
        #expect(engine.beatPhase == 0)
    }
}
