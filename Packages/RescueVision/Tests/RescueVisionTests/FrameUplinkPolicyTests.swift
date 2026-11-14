import Testing
@testable import RescueVision

/// `#expect` can't call a mutating method on a local, so hold the policy in a class.
private final class Gate {
    var policy = FrameUplinkPolicy()

    init(open: Bool = true) {
        if open { policy.setOpen(true) }
    }

    func send(at now: Double) -> Bool { policy.shouldSend(at: now) }

    /// Offers a frame at 60 FPS for the given time and returns when each was let through.
    func run(from start: Double, seconds: Double) -> [Double] {
        (0..<Int(seconds * 60)).compactMap { tick in
            let now = start + Double(tick) / 60
            return send(at: now) ? now : nil
        }
    }
}

@Test func closedByDefaultAndNothingPasses() {
    let gate = Gate(open: false)
    #expect(!gate.policy.isOpen)
    #expect(gate.run(from: 0, seconds: 60).isEmpty)
}

@Test func nothingPassesWhenClosedEvenInABurst() {
    let gate = Gate()
    #expect(gate.send(at: 0))
    gate.policy.setOpen(false)
    gate.policy.beginBurst(at: 1)
    #expect(gate.run(from: 1, seconds: 60).isEmpty)
}

@Test func idleRateIsOnePerSecond() {
    let gate = Gate()
    let sent = gate.run(from: 0, seconds: 30)
    #expect(sent.count == 30 || sent.count == 31)
    for (a, b) in zip(sent, sent.dropFirst()) {
        #expect(b - a >= 1)
        #expect(b - a <= 1.1)
    }
}

@Test func burstIsAtMostOnePerSecondForThreeSeconds() {
    let gate = Gate()
    #expect(gate.send(at: 0))
    gate.policy.beginBurst(at: 10)
    let sent = gate.run(from: 10, seconds: 3)
    #expect(sent.count == 3)
    for (a, b) in zip(sent, sent.dropFirst()) { #expect(b - a >= 1) }

    let after = gate.run(from: 13, seconds: 20)
    #expect(after.count <= 21)
    for (a, b) in zip(after, after.dropFirst()) { #expect(b - a >= 1) }
}

/// Bursts only, as on an awake step, where nothing goes out between bursts.
@Test func closingEndsABurstForGood() {
    let gate = Gate()
    gate.policy.setBurstsOnly(true)
    gate.policy.beginBurst(at: 0)
    #expect(gate.send(at: 0))
    gate.policy.setOpen(false)
    #expect(!gate.send(at: 1))
    gate.policy.setOpen(true)
    #expect(!gate.send(at: 2), "the burst must not resume after the gate reopens")
    gate.policy.beginBurst(at: 5)
    #expect(gate.send(at: 5))
}

@Test func reopeningDoesNotBeatTheInterval() {
    let gate = Gate()
    #expect(gate.send(at: 0))
    gate.policy.setOpen(false)
    gate.policy.setOpen(true)
    #expect(!gate.send(at: 0.9))
}

@Test func thermalScalingStretchesButStaysInRange() {
    let gate = Gate()
    gate.policy.setIntervalScale(2)
    #expect(gate.send(at: 0))
    #expect(!gate.send(at: 1.9))
    #expect(gate.send(at: 2))

    gate.policy.beginBurst(at: 20)
    #expect(gate.send(at: 20))
    #expect(!gate.send(at: 21))
    #expect(gate.send(at: 22))

    gate.policy.setIntervalScale(100)
    #expect(gate.send(at: 32))
    #expect(!gate.send(at: 35.9))
    #expect(gate.send(at: 36), "idle never goes past 4 s")
}
