import Testing
@testable import RescueAudio

@Suite struct SpeechGateTests {
    private let oneSecond = 24_000

    @Test func closedByDefaultAndDropsAudio() {
        let gate = SpeechGate(sampleRate: oneSecond)
        #expect(!gate.isOpen)
        #expect(gate.admit(sampleCount: 100) == .closed)
    }

    @Test func openPassesAndClosingDropsAgain() {
        let gate = SpeechGate(sampleRate: oneSecond)
        gate.setOpen(true)
        #expect(gate.admit(sampleCount: 100) == .pass(sampleCount: 100))
        gate.setOpen(false)
        #expect(gate.admit(sampleCount: 100) == .closed)
    }

    @Test func closedAudioDoesNotSpendTheTurnBudget() {
        let gate = SpeechGate(sampleRate: oneSecond)
        _ = gate.admit(sampleCount: oneSecond * 100)
        gate.setOpen(true)
        #expect(gate.admit(sampleCount: 100) == .pass(sampleCount: 100))
    }

    @Test func runawayGuardStopsATurnAtExactlyTwentySeconds() {
        let gate = SpeechGate(sampleRate: oneSecond)
        gate.setOpen(true)
        for _ in 0..<19 {
            #expect(gate.admit(sampleCount: oneSecond) == .pass(sampleCount: oneSecond))
        }
        // This chunk crosses the limit, so only the part inside the 20 s budget passes.
        #expect(gate.admit(sampleCount: oneSecond + 500) == .pass(sampleCount: oneSecond))
        #expect(gate.admit(sampleCount: 1) == .runaway(justTripped: true))
        #expect(gate.admit(sampleCount: 1) == .runaway(justTripped: false))
    }

    @Test func anEmptyChunkNeverTripsTheGuard() {
        let gate = SpeechGate(sampleRate: oneSecond)
        gate.setOpen(true)
        #expect(gate.admit(sampleCount: 0) == .pass(sampleCount: 0))
        _ = gate.admit(sampleCount: oneSecond * 20)
        #expect(gate.admit(sampleCount: 0) == .pass(sampleCount: 0))
        #expect(gate.admit(sampleCount: 1) == .runaway(justTripped: true))
    }

    @Test func aNewTurnGetsAFreshBudget() {
        let gate = SpeechGate(sampleRate: oneSecond)
        gate.setOpen(true)
        _ = gate.admit(sampleCount: oneSecond * 20)
        #expect(gate.admit(sampleCount: 1) == .runaway(justTripped: true))
        gate.endTurn()
        #expect(gate.admit(sampleCount: oneSecond) == .pass(sampleCount: oneSecond))
    }

    @Test func closingDoesNotResetTheTurnBudget() {
        let gate = SpeechGate(sampleRate: oneSecond)
        gate.setOpen(true)
        _ = gate.admit(sampleCount: oneSecond * 20)
        gate.setOpen(false)
        gate.setOpen(true)
        #expect(gate.admit(sampleCount: 1) == .runaway(justTripped: true))
    }
}
