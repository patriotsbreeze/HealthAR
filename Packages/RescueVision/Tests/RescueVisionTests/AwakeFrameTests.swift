import CoreGraphics
import CoreVideo
import Foundation
@testable import RescueCore
import Testing
@testable import RescueVision

/// Offers a frame at 60 FPS for the given time and returns when each was let through.
private func sends(_ policy: inout FrameUplinkPolicy, from start: Double, seconds: Double) -> [Double] {
    (0..<Int(seconds * 60)).compactMap { tick in
        let now = start + Double(tick) / 60
        return policy.shouldSend(at: now) ? now : nil
    }
}

@Test func burstsOnlyTakesAwayTheIdleRate() {
    var policy = FrameUplinkPolicy()
    policy.setOpen(true)
    policy.setBurstsOnly(true)
    #expect(sends(&policy, from: 0, seconds: 30).isEmpty)
}

@Test func burstsOnlyStillSendsDuringABurstAtTheBurstRate() {
    var policy = FrameUplinkPolicy()
    policy.setOpen(true)
    policy.setBurstsOnly(true)
    policy.beginBurst(at: 10)
    let sent = sends(&policy, from: 10, seconds: 3)
    #expect(sent.count == 3)
    for (a, b) in zip(sent, sent.dropFirst()) { #expect(b - a >= 1) }
    #expect(sends(&policy, from: 13, seconds: 20).isEmpty, "nothing once the burst is over")
}

@Test func burstsOnlyNeverOpensAClosedGate() {
    var policy = FrameUplinkPolicy()
    policy.setBurstsOnly(true)
    policy.beginBurst(at: 0)
    #expect(sends(&policy, from: 0, seconds: 5).isEmpty)
}

@Test func leavingBurstsOnlyBringsTheIdleRateBack() {
    var policy = FrameUplinkPolicy()
    policy.setOpen(true)
    policy.setBurstsOnly(true)
    #expect(sends(&policy, from: 0, seconds: 1).isEmpty)
    policy.setBurstsOnly(false)
    #expect(!sends(&policy, from: 1, seconds: 1).isEmpty)
}

/// The merged bundle's rule for an awake state: frames go when someone is talking, and only then.
@Test func anAwakeStateSendsFramesOnBurstsAlone() async throws {
    let clinical = repoRoot().appendingPathComponent("clinical")
    let core = try ProtocolBundle(
        protocolData: Data(contentsOf: clinical.appendingPathComponent("adult_arrest.v1.json")),
        phrasesData: Data(contentsOf: clinical.appendingPathComponent("phrases.v1.json"))
    )
    let bundle = core.merging(
        modules: ScenarioModule.manifest.map { id in
            ModuleSource(id: id, data: try? Data(contentsOf: clinical.appendingPathComponent("modules/\(id).json")))
        },
        pack: try? Data(contentsOf: clinical.appendingPathComponent("\(KnowledgePack.id).json"))
    )
    let engine = ProtocolEngine(bundle: bundle)
    let clock = TestClock()
    let session = VisionSession(
        locator: FixedLocator(box: nil),
        driver: FakeDriver(),
        detect: { _, _ in [] },
        clock: { clock.now },
        runsPump: false
    )
    session.viewportSize = portraitMapping.viewSize

    let start = engine.start(at: clock.now)
    var state = start.state
    start.effects.forEach(session.apply)
    for action in [HumanAction.yes, .triageChest, .done, .yes, .scan] {
        let result = engine.reduce(state, .human(action), at: clock.now)
        state = result.state
        result.effects.forEach(session.apply)
    }
    #expect(state.stateID == "chest_scan")

    func sentOver(seconds: Int) async -> Int {
        var sent = 0
        for _ in 0..<(60 * seconds) {
            if let frame = session.ingest(pixels: makePixels(), pose: cameraPose(), tracking: .normal, imageToView: portraitMapping.imageToView),
               await session.process(frame) {
                sent += 1
            }
            clock.advance(1.0 / 60)
        }
        return sent
    }

    #expect(await sentOver(seconds: 11) == 0, "nobody is talking")
    session.beginFrameBurst()
    #expect(await sentOver(seconds: 3) == 3)
}

/// Burst-only rules frames for the model, not the locate a person asked for by tapping Scan room.
@Test func aPendingLocateStillGoesOnAFrameTheUplinkWouldNotSend() async throws {
    let clock = TestClock()
    let session = VisionSession(
        locator: FixedLocator(box: nil),
        driver: FakeDriver(),
        detect: { _, _ in [] },
        clock: { clock.now },
        runsPump: false
    )
    session.viewportSize = portraitMapping.viewSize
    session.apply(.policyChanged(RuntimePolicy(modelSpeechOpen: false, micUplink: true, frameUplink: true, audioMode: .full, frameBurstsOnly: true)))
    session.apply(.locate(.aed))

    let frame = try #require(session.ingest(pixels: makePixels(), pose: cameraPose(), tracking: .normal, imageToView: portraitMapping.imageToView))
    #expect(await session.process(frame) == false, "nothing went to the model")

    let deadline = Date().addingTimeInterval(5)
    while session.aedStatus != .notFound, Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.aedStatus == .notFound, "the locator did answer")
}
