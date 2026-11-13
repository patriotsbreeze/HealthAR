import CoreGraphics
import CoreVideo
import Foundation
import RescueCore
import Synchronization
import Testing
import simd
@testable import RescueVision

private let lying = person(center: [0.5, 0.6], axisDegrees: 0, aspect: 4.0 / 3)
private let portraitTransform = portraitMapping.imageToView
private let box = NormalizedBox(minX: 0.65, minY: 0.2, maxX: 0.85, maxY: 0.3)!

/// A session with no pump, so each test steps frames by hand.
private func makeSession(
    clock: TestClock,
    driver: FakeDriver = FakeDriver(),
    locator: any ObjectLocating = FixedLocator(box: nil),
    people: [DetectedPerson] = [lying]
) -> VisionSession {
    let session = VisionSession(
        locator: locator,
        driver: driver,
        detect: { _, _ in people },
        clock: { clock.now },
        runsPump: false
    )
    session.viewportSize = portraitMapping.viewSize
    return session
}

private struct Step {
    var wantedPixels = false
    var sentUplink = false
}

@discardableResult
private func step(
    _ session: VisionSession,
    pose: CameraPose = cameraPose(),
    tracking: TrackingQuality = .normal
) async -> Step {
    let frame = session.ingest(pixels: makePixels(), pose: pose, tracking: tracking, imageToView: portraitTransform)
    guard let frame else { return Step() }
    return Step(wantedPixels: true, sentUplink: await session.process(frame))
}

// MARK: - Ring

/// The core times place_hands out at 5 s, so the ring lasts the step rather than a window inside it.
@Test func ringShowsForTheWholeStep() async throws {
    let clock = TestClock()
    let session = makeSession(clock: clock)
    #expect(session.overlay() == .empty)

    session.apply(.overlay(.chestCenter))
    await step(session)
    let ring = try #require(session.overlay().ring)
    let expected = portraitMapping.ring(for: try #require(TorsoMap.target(for: lying.torso, imageAspect: 4.0 / 3)))
    #expect(ring == expected)
    #expect(session.keypointAge == 0)

    clock.advance(4.9)
    let late = await step(session)
    #expect(late.wantedPixels, "past the old 3 s window")
    #expect(session.overlay().ring == expected)

    session.apply(.overlay(nil))
    #expect(session.overlay().ring == nil)
    #expect(await !step(session).wantedPixels, "nothing needs pixels once the step is over")
}

@Test func ringHidesWhenKeypointsGoStaleEvenInsideTheWindow() async {
    let clock = TestClock()
    let session = makeSession(clock: clock)
    session.apply(.overlay(.chestCenter))
    await step(session)
    #expect(session.overlay().ring != nil)

    clock.advance(0.1)
    session.ingest(pixels: makePixels(), pose: cameraPose(), tracking: .normal, imageToView: portraitTransform)
    #expect(session.overlay().ring != nil)
    clock.advance(0.11)
    session.ingest(pixels: makePixels(), pose: cameraPose(), tracking: .normal, imageToView: portraitTransform)
    #expect(session.overlay().ring == nil)
}

@Test func leavingTheStateHidesTheRing() async {
    let clock = TestClock()
    let session = makeSession(clock: clock)
    session.apply(.overlay(.chestCenter))
    await step(session)
    session.apply(.overlay(nil))
    #expect(session.overlay() == .empty)
}

@Test func poseRunsAtTheGovernedRate() async {
    let clock = TestClock()
    let runs = Mutex(0)
    let session = VisionSession(
        locator: FixedLocator(box: nil),
        driver: FakeDriver(),
        detect: { _, _ in
            runs.withLock { $0 += 1 }
            return []
        },
        clock: { clock.now },
        runsPump: false
    )
    session.apply(.overlay(.chestCenter))
    session.setThermalState(.serious)
    for _ in 0..<60 {
        await step(session)
        clock.advance(1.0 / 60)
    }
    let count = runs.withLock { $0 }
    #expect((10...16).contains(count), "got \(count) in one second")
}

/// Compressions takes no pixels, with one deliberate exception: the hands guide the coordinator
/// opens as compressions begins on Start CPR, which skips place_hands. Pose runs on the phone for
/// those seconds only, and nothing is sent.
@Test func nothingWantsPixelsDuringCompressionsOutsideTheHandsGuide() async throws {
    let clock = TestClock()
    let session = makeSession(clock: clock)
    session.setFrameUplink(false)
    session.apply(.overlay(nil))
    #expect(await !step(session).wantedPixels)
    #expect(!session.showsHandsGuide)

    session.beginHandsGuide()
    #expect(session.showsHandsGuide)
    let inside = await step(session)
    #expect(inside.wantedPixels)
    #expect(!inside.sentUplink)
    #expect(session.overlay().ring != nil, "the hands show on the chest")
    #expect(session.overlay().zones.map(\.kind) == [.chest])

    clock.advance(VisionSession.handsGuideSeconds - 0.01)
    #expect(await step(session).wantedPixels)
    clock.advance(0.01)
    #expect(!session.showsHandsGuide)
    #expect(await !step(session).wantedPixels, "none once it ends")
    #expect(session.overlay() == .empty)
    clock.advance(30)
    #expect(await !step(session).wantedPixels)
}

@Test func theHandsGuideEndsWithTheStepAndNeedsAStepWithNoOverlay() async {
    let clock = TestClock()
    let session = makeSession(clock: clock)
    session.apply(.overlay(nil))
    session.beginHandsGuide()
    #expect(await step(session).wantedPixels)

    // aed_analyze has no overlay either, and the hands must not show there.
    session.apply(.overlay(nil))
    #expect(!session.showsHandsGuide)
    #expect(await !step(session).wantedPixels)

    session.beginHandsGuide()
    session.endHandsGuide()
    #expect(await !step(session).wantedPixels)

    session.apply(.overlay(.aedDevice))
    session.beginHandsGuide()
    #expect(!session.showsHandsGuide, "a step with a mark of its own keeps it")
}

/// The carried AED's arrow never sits beside the hands. It comes back once the guide is over.
@Test func theCarriedArrowWaitsForTheHandsGuide() async throws {
    let clock = TestClock()
    let wall: @Sendable (WorldRay) -> SIMD3<Float>? = { _ in [0, 0, -4] }
    let session = makeSession(clock: clock, driver: FakeDriver(surface: wall), locator: FixedLocator(box: box))
    session.setFrameUplink(true)
    session.setAEDCarry(findsCarry: true, showsCarried: false)
    session.apply(.overlay(.aedDevice))
    session.apply(.locate(.aed))
    await step(session)
    #expect(await waitUntil { session.aedStatus == .located })

    session.setFrameUplink(false)
    session.setAEDCarry(findsCarry: false, showsCarried: true)
    session.apply(.overlay(nil))
    session.beginHandsGuide()
    await step(session)
    #expect(session.overlay().ring != nil)
    #expect(session.overlay().aedArrow == nil)

    clock.advance(VisionSession.handsGuideSeconds)
    await step(session)
    #expect(session.overlay().ring == nil)
    #expect(session.overlay().aedArrow != nil)
}

// MARK: - Uplink

@Test func noUplinkWhenClosedHoweverHardItIsAsked() async {
    let clock = TestClock()
    let session = makeSession(clock: clock)
    session.apply(.overlay(.chestCenter))
    session.beginFrameBurst()
    session.requestLocate(.aed)
    var sent = 0
    for _ in 0..<120 {
        if await step(session).sentUplink { sent += 1 }
        clock.advance(0.5)
    }
    #expect(sent == 0)
}

@Test func uplinkFollowsTheRateGateWhenOpen() async {
    let clock = TestClock()
    let session = makeSession(clock: clock)
    session.setFrameUplink(true)
    var sent = 0
    for _ in 0..<(60 * 11) {
        if await step(session).sentUplink { sent += 1 }
        clock.advance(1.0 / 60)
    }
    #expect(sent == 3, "at 0, 5, and 10 s")
}

@Test func closingBeforeTheFrameIsWorkedStillBlocksIt() async throws {
    let session = makeSession(clock: TestClock())
    session.setFrameUplink(true)
    let frame = session.ingest(pixels: makePixels(), pose: cameraPose(), tracking: .normal, imageToView: portraitTransform)
    session.setFrameUplink(false)
    let sent = await session.process(try #require(frame))
    #expect(!sent)
}

/// Encoding takes time, and the engine can close the uplink during it. No test can get in there
/// without a seam, and the check before encoding would otherwise hide this one.
@Test func closingDuringEncodingStillBlocksTheFrameAndTheLocate() async throws {
    let clock = TestClock()
    let locator = GatedLocator()
    let closing = Mutex<VisionSession?>(nil)
    let session = VisionSession(
        locator: locator,
        driver: FakeDriver(),
        detect: { _, _ in [] },
        clock: { clock.now },
        runsPump: false,
        encode: { _, _ in
            closing.withLock { $0?.setFrameUplink(false) }
            return Data([0xFF, 0xD8])
        }
    )
    closing.withLock { $0 = session }
    defer { closing.withLock { $0 = nil } }
    session.setFrameUplink(true)
    session.apply(.locate(.aed))

    let frame = session.ingest(pixels: makePixels(), pose: cameraPose(), tracking: .normal, imageToView: nil)
    let sent = await session.process(try #require(frame))
    #expect(!sent)
    try await Task.sleep(for: .milliseconds(50))
    #expect(locator.calls == 0)
}

@Test func uplinkFramesCarryTheirFrameIDAndAJPEG() async throws {
    let clock = TestClock()
    let session = makeSession(clock: clock)
    session.setFrameUplink(true)
    await step(session)
    session.finishStreams()
    var iterator = session.uplinkFrames.makeAsyncIterator()
    let frame = try #require(await iterator.next())
    #expect(frame.frameID == 1)
    #expect(frame.capturedAt == clock.now)
    #expect(frame.jpeg.starts(with: [0xFF, 0xD8]))
}

/// The real engine and clinical protocol decide. No frame leaves during pads (invariant 11): the
/// pad zones come from pose on the phone, and nothing is sent or located.
@Test func engineStatesOpenAndCloseTheUplink() async throws {
    let clinical = repoRoot().appendingPathComponent("clinical")
    let bundle = try ProtocolBundle(
        protocolData: Data(contentsOf: clinical.appendingPathComponent("adult_arrest.v1.json")),
        phrasesData: Data(contentsOf: clinical.appendingPathComponent("phrases.v1.json"))
    )
    let engine = ProtocolEngine(bundle: bundle)
    let clock = TestClock()
    let locator = GatedLocator()
    let session = makeSession(clock: clock, locator: locator)
    defer { locator.release(nil) }

    let start = engine.start(at: clock.now)
    var engineState = start.state
    start.effects.forEach(session.apply)

    func tap(_ action: HumanAction) {
        let result = engine.reduce(engineState, .human(action), at: clock.now)
        engineState = result.state
        result.effects.forEach(session.apply)
    }

    /// Tries hard to get frames out for ten seconds and counts what actually left.
    func framesSent() async -> (wanted: Bool, sent: Int) {
        var wanted = false
        var sent = 0
        for _ in 0..<(10 * 4) {
            clock.advance(0.25)
            session.beginFrameBurst()
            let result = await step(session)
            wanted = wanted || result.wantedPixels
            if result.sentUplink { sent += 1 }
        }
        return (wanted, sent)
    }

    tap(.startCpr)
    #expect(engineState.stateID == "compressions")
    let compressions = await framesSent()
    #expect(compressions.sent == 0)
    #expect(!compressions.wanted, "no hands guide was asked for")

    tap(.scan)
    #expect(engineState.stateID == "resource_scan")
    #expect(await framesSent().sent >= 2)

    tap(.aedHere)
    #expect(engineState.stateID == "aed_on")
    #expect(await framesSent().sent == 0)

    tap(.done)
    #expect(engineState.stateID == "pads")
    session.apply(.locate(.aed))
    session.requestLocate([.towel, .aed])
    let pads = await framesSent()
    #expect(pads.sent == 0)
    #expect(pads.wanted, "pose runs on the phone for the pad zones")
    #expect(session.overlay().zones.map(\.kind) == [.pad(1), .pad(2)])
    try await Task.sleep(for: .milliseconds(50))
    #expect(locator.calls == 0, "and no frame goes to the locator either")

    tap(.padsOn)
    #expect(engineState.stateID == "aed_analyze")
    let analyze = await framesSent()
    #expect(analyze.sent == 0)
    #expect(!analyze.wanted, "hands off during analysis")
    #expect(session.overlay() == .empty)
}

// MARK: - AED

@Test func aLateAnswerUsesTheStoredPoseAndTheArrowUsesTheCurrentOne() async throws {
    let clock = TestClock()
    let locator = GatedLocator()
    let wall: @Sendable (WorldRay) -> SIMD3<Float>? = { ray in
        ray.origin + ray.direction * ((-4 - ray.origin.z) / ray.direction.z)
    }
    let session = makeSession(clock: clock, driver: FakeDriver(surface: wall), locator: locator)
    let stored = cameraPose(transform(position: [0, 1.2, 0]))
    let moved = cameraPose(transform(rotationY: 40, position: [3, 1.2, -1]))

    session.setFrameUplink(true)
    session.apply(.overlay(.aedDevice))
    session.apply(.locate(.aed))
    await step(session, pose: stored)
    #expect(await waitUntil { locator.calls == 1 })
    #expect(locator.labels == ["aed"])
    #expect(session.aedStatus == .locating)

    // The phone moves on for seconds while the model thinks.
    clock.advance(5)
    await step(session, pose: moved)
    #expect(session.overlay().aedArrow == nil, "no answer yet")

    locator.release(box)
    #expect(await waitUntil { session.aedStatus == .located })

    let display = SIMD2<Double>(0.75, 0.25)
    let expected = try #require(wall(stored.ray(throughImagePoint: CaptureRotation.right.captureNormalized(fromDisplay: display))))
    let wrong = try #require(wall(moved.ray(throughImagePoint: CaptureRotation.right.captureNormalized(fromDisplay: display))))
    let point = try #require(session.objects.worldPoint(.aed))
    #expect(isClose(point, expected))
    #expect(!isClose(point, wrong, 0.5))

    let arrow = try #require(session.overlay().aedArrow)
    #expect(arrow == portraitMapping.arrow(to: expected, camera: moved))
}

@Test func locateIsDroppedWhenTheUplinkIsClosed() async {
    let locator = GatedLocator()
    let session = makeSession(clock: TestClock(), locator: locator)
    session.apply(.locate(.aed))
    #expect(await !step(session).wantedPixels)
    session.setFrameUplink(true)
    await step(session)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(locator.calls == 0)
}

@Test func closingTheUplinkCancelsAPendingLocate() async {
    let locator = GatedLocator()
    let session = makeSession(clock: TestClock(), locator: locator)
    session.setFrameUplink(true)
    session.apply(.locate(.aed))
    session.setFrameUplink(false)
    session.setFrameUplink(true)
    await step(session)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(locator.calls == 0)
}

@Test func locateWaitsForGoodTracking() async {
    let locator = GatedLocator()
    let session = makeSession(clock: TestClock(), locator: locator)
    session.setFrameUplink(true)
    session.apply(.locate(.aed))
    await step(session, tracking: .limited)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(locator.calls == 0)
    await step(session, tracking: .normal)
    #expect(await waitUntil { locator.calls == 1 })
    locator.release(nil)
}

@Test func arrowHidesWithPoorTrackingOrNoRecentFrame() async {
    let clock = TestClock()
    let wall: @Sendable (WorldRay) -> SIMD3<Float>? = { _ in [0, 0, -4] }
    let session = makeSession(clock: clock, driver: FakeDriver(surface: wall), locator: FixedLocator(box: box))
    session.setFrameUplink(true)
    session.apply(.overlay(.aedDevice))
    session.apply(.locate(.aed))
    await step(session)
    #expect(await waitUntil { session.aedStatus == .located })
    #expect(session.overlay().aedArrow != nil)

    await step(session, tracking: .limited)
    #expect(session.overlay().aedArrow == nil)

    await step(session)
    #expect(session.overlay().aedArrow != nil)
    clock.advance(VisionOverlay.maxCameraAge + 0.01)
    #expect(session.overlay().aedArrow == nil)

    await step(session)
    session.apply(.overlay(nil))
    #expect(session.overlay().aedArrow == nil, "the engine decides when the arrow shows")
}

// MARK: - Lifecycle and thermal

/// A session that has located the AED at a fixed world point.
private func sessionWithLocatedAED(clock: TestClock, driver: FakeDriver) async -> VisionSession {
    let session = makeSession(clock: clock, driver: driver, locator: FixedLocator(box: box))
    session.setFrameUplink(true)
    session.apply(.overlay(.aedDevice))
    session.apply(.locate(.aed))
    await step(session)
    #expect(await waitUntil { session.aedStatus == .located })
    return session
}

private let wallDriver: @Sendable () -> FakeDriver = { FakeDriver(surface: { _ in [0, 0, -4] }) }

@Test func thermalCriticalTurnsAROffAndForgetsTheWorld() async {
    let clock = TestClock()
    let driver = wallDriver()
    let session = await sessionWithLocatedAED(clock: clock, driver: driver)
    session.start()
    #expect(driver.runs == 1)
    #expect(session.status == .running)
    #expect(session.overlay().aedArrow != nil)

    session.setThermalState(.serious)
    #expect(driver.pauses == 0)
    #expect(session.overlay().aedArrow != nil, "slower inference doesn't touch tracking")

    session.setThermalState(.critical)
    #expect(driver.pauses == 1)
    #expect(session.status == .shedForHeat)
    #expect(session.overlay() == .empty)
    #expect(session.objects.worldPoint(.aed) == nil)

    session.setThermalState(.fair)
    #expect(driver.runs == 2)
    #expect(session.status == .running)
    #expect(session.objects.worldPoint(.aed) == nil, "the new session is a new world")
}

@Test func anInterruptionForgetsTheWorld() async {
    let session = await sessionWithLocatedAED(clock: TestClock(), driver: wallDriver())
    #expect(session.overlay().aedArrow != nil)
    session.forgetWorld()
    #expect(session.objects.worldPoint(.aed) == nil)
    #expect(session.overlay() == .empty)
    #expect(session.displayMapping == nil)
}

@Test func anAnswerArrivingAfterAnInterruptionIsDropped() async throws {
    let locator = GatedLocator()
    let session = makeSession(clock: TestClock(), driver: wallDriver(), locator: locator)
    session.setFrameUplink(true)
    session.apply(.locate(.aed))
    await step(session)
    #expect(await waitUntil { locator.calls == 1 })
    session.forgetWorld()
    locator.release(box)
    try await Task.sleep(for: .milliseconds(50))
    #expect(session.objects.worldPoint(.aed) == nil)
}

@Test func aFrameFromBeforeAnInterruptionIsNotUsed() async throws {
    let locator = GatedLocator()
    let session = makeSession(clock: TestClock(), locator: locator)
    session.setFrameUplink(true)
    session.apply(.locate(.aed))
    let frame = session.ingest(pixels: makePixels(), pose: cameraPose(), tracking: .normal, imageToView: nil)
    session.forgetWorld()
    let sent = await session.process(try #require(frame))
    #expect(!sent)
    try await Task.sleep(for: .milliseconds(50))
    #expect(locator.calls == 0)
}

@Test func stoppingForgetsTheWorld() async {
    let session = await sessionWithLocatedAED(clock: TestClock(), driver: wallDriver())
    session.stop()
    #expect(session.objects.worldPoint(.aed) == nil)
    #expect(session.displayMapping == nil)
    #expect(session.status == .stopped)
}

@Test func aFailedSessionReportsItAndCanRetry() async {
    let driver = FakeDriver()
    let session = makeSession(clock: TestClock(), driver: driver)
    session.start()
    session.driverFailed()
    #expect(session.status == .failed)
    #expect(session.overlay() == .empty)

    session.setThermalState(.fair)
    #expect(driver.runs == 1, "only an explicit start retries")

    session.start()
    #expect(session.status == .running)
    #expect(driver.runs == 2)
}

@Test func unsupportedHardwareNoOpsEverywhere() async {
    let driver = FakeDriver(isSupported: false)
    let locator = GatedLocator()
    let session = makeSession(clock: TestClock(), driver: driver, locator: locator)
    #expect(!session.isARSupported)
    #expect(session.status == .unsupported)
    session.start()
    #expect(driver.runs == 0)
    session.apply(.overlay(.chestCenter))
    session.setFrameUplink(true)
    session.apply(.locate(.aed))
    session.beginFrameBurst()
    session.setThermalState(.critical)
    #expect(session.overlay() == .empty)
    #expect(session.displayMapping == nil)
    session.stop()
    #expect(locator.calls == 0)
}

@Test func publicInitIsACleanNoOpWithoutACamera() async {
    let session = VisionSession(locator: FixedLocator(box: nil))
    #if !os(iOS)
    #expect(session.status == .unsupported)
    #expect(!session.isARSupported)
    #endif
    session.start()
    session.apply(.overlay(.chestCenter))
    session.apply(.locate(.aed))
    #expect(session.overlay() == .empty)
    session.stop()
}

@Test func effectsVisionHasNoPartInAreIgnored() {
    let session = makeSession(clock: TestClock())
    session.apply(.metronome(on: true))
    session.apply(.playPhrase("hands_center"))
    session.apply(.flushModelAudio)
    #expect(session.overlay() == .empty)
}

// MARK: - Pixel buffers

/// Dies with the pixel buffer it is attached to.
private final class BufferTracker {
    static let live = Mutex(0)
    init() { Self.live.withLock { $0 += 1 } }
    deinit { Self.live.withLock { $0 -= 1 } }
}

@Test func holdsAtMostTwoPixelBuffersUnderASlowWorker() async throws {
    let clock = TestClock()
    let session = VisionSession(
        locator: FixedLocator(box: nil),
        driver: FakeDriver(),
        detect: { _, _ in
            try? await Task.sleep(for: .milliseconds(15))
            return []
        },
        clock: { clock.now },
        runsPump: true
    )
    session.apply(.overlay(.chestCenter))

    var peak = 0
    // Each step passes the pose rate limit, so the worker really is busy, and all stay in the window.
    for _ in 0..<80 {
        do {
            let pixels = makePixels()
            CVBufferSetAttachment(pixels, "tracker" as CFString, BufferTracker(), .shouldNotPropagate)
            session.ingest(pixels: pixels, pose: cameraPose(), tracking: .normal, imageToView: portraitTransform)
        }
        peak = max(peak, BufferTracker.live.withLock { $0 })
        clock.advance(0.034)
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(peak == 2, "peak was \(peak)")
}

@Test func mailboxDeliversTheNewestFrame() async throws {
    let session = makeSession(clock: TestClock())
    session.apply(.overlay(.chestCenter))
    var last: CapturedFrame?
    for _ in 0..<10 {
        last = session.ingest(pixels: makePixels(), pose: cameraPose(), tracking: .normal, imageToView: nil)
    }
    var iterator = session.frames.makeAsyncIterator()
    let delivered = try #require(await iterator.next())
    #expect(delivered.id == last?.id)
}
