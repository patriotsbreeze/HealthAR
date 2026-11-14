import CoreGraphics
import Foundation
@testable import RescueCore
import Synchronization
import Testing
import simd
@testable import RescueVision

private let portraitTransform = portraitMapping.imageToView
private let box = NormalizedBox(minX: 0.65, minY: 0.2, maxX: 0.85, maxY: 0.3)!
private let onLimb: SIMD3<Float> = [0.2, -0.3, -1.5]
/// Off the view's center line, where forgetting the crop would land somewhere else.
private let tap = CGPoint(x: 120, y: 500)

private func makeSession(clock: TestClock, driver: any CameraDriver, locator: any ObjectLocating = FixedLocator(box: nil)) -> VisionSession {
    let session = VisionSession(locator: locator, driver: driver, detect: { _, _ in [] }, clock: { clock.now }, runsPump: false)
    session.viewportSize = portraitMapping.viewSize
    return session
}

@discardableResult
private func step(_ session: VisionSession, pose: CameraPose = cameraPose(), tracking: TrackingQuality = .normal) async -> Bool {
    guard let frame = session.ingest(pixels: makePixels(), pose: pose, tracking: tracking, imageToView: portraitTransform) else { return false }
    return await session.process(frame)
}

private func wall(_ ray: WorldRay) -> SIMD3<Float>? { ray.origin + ray.direction * 2 }

// MARK: - compose

private func record(tracking: TrackingQuality = .normal, at time: TimeInterval = 100) -> FrameRecord {
    FrameRecord(id: 1, timestamp: time, pose: cameraPose(), tracking: tracking)
}

private let carried: SIMD3<Float> = [0, 0, -4]
private let pinArrow = portraitMapping.pin(at: onLimb, camera: cameraPose())
private let pinRing = portraitMapping.pressRing(at: onLimb, camera: cameraPose())!
private let aedArrow = portraitMapping.arrow(to: carried, camera: cameraPose())

private func compose(
    _ target: OverlayTarget?,
    camera: FrameRecord? = record(),
    mapping: DisplayMapping? = portraitMapping,
    aedPoint: SIMD3<Float>? = nil,
    carriedAED: SIMD3<Float>? = nil,
    pinPlacedAt: TimeInterval? = nil,
    now: TimeInterval = 100
) -> VisionOverlay {
    VisionOverlay.compose(
        target: target,
        ring: .hidden,
        camera: camera,
        mapping: mapping,
        aedPoint: aedPoint,
        carriedAED: carriedAED,
        injuryPin: pinPlacedAt.map { PlacedPin(world: onLimb, placedAt: $0) },
        now: now
    )
}

@Test func nothingPlacedAndALiveCameraShowsOnlyTheHint() {
    #expect(compose(.injurySite) == VisionOverlay(showsInjuryHint: true))
    #expect(compose(.injurySite, camera: record(tracking: .limited)) == VisionOverlay(showsInjuryHint: true))
}

@Test func withNoLiveCameraTheHintAndPinAreBothGone() {
    #expect(compose(.injurySite, camera: nil) == .empty)
    #expect(compose(.injurySite, mapping: nil) == .empty)
    let stale = 100 + VisionOverlay.maxCameraAge + 0.01
    #expect(compose(.injurySite, now: stale) == .empty)
    #expect(compose(.injurySite, pinPlacedAt: 100, now: stale) == .empty)
}

@Test func aPlacedPinShowsOnlyWithNormalTracking() {
    #expect(compose(.injurySite, pinPlacedAt: 99) == VisionOverlay(injuryPin: pinArrow, zones: [pinRing]))
    #expect(compose(.injurySite, camera: record(tracking: .limited), pinPlacedAt: 99) == .empty, "no hint, since one is placed")
    #expect(compose(.injurySite, camera: record(tracking: .notAvailable), pinPlacedAt: 99) == .empty)
}

@Test func aPinExpiresAfterTwentySecondsAndTheHintComesBack() {
    let placed = 100 - VisionOverlay.pinSeconds
    #expect(compose(.injurySite, pinPlacedAt: placed + 0.01).injuryPin != nil)
    #expect(compose(.injurySite, pinPlacedAt: placed) == VisionOverlay(showsInjuryHint: true))
}

/// Held this way, the camera's +x is down the screen, so a pin behind and to that side points down.
@Test func aPinBehindThePhoneIsOffScreenWithAWayToTurn() {
    let pin = portraitMapping.pin(at: [0.5, 0, 2], camera: cameraPose())
    #expect(!pin.isOnScreen)
    #expect((0...1).contains(pin.position.x) && (0...1).contains(pin.position.y))
    #expect(abs(pin.angle - .pi / 2) < 1e-6)
    #expect(pin.position.y > 0.9)

    let other = portraitMapping.pin(at: [-0.5, 0, 2], camera: cameraPose())
    #expect(abs(other.angle + .pi / 2) < 1e-6, "the other side turns the other way")
}

@Test(arguments: [OverlayTarget.chestCenter, .aedDevice, .padZones, nil])
func noOtherTargetDrawsThePinOrTheHint(target: OverlayTarget?) {
    let overlay = compose(target, pinPlacedAt: 99)
    #expect(overlay.injuryPin == nil)
    #expect(!overlay.showsInjuryHint)
}

@Test func theCarriedArrowNeedsANormalCameraAndNoOverlayOfItsOwn() {
    #expect(compose(nil, carriedAED: carried) == VisionOverlay(aedArrow: aedArrow))
    #expect(compose(nil, camera: record(tracking: .limited), carriedAED: carried) == .empty)
    #expect(compose(nil, camera: nil, carriedAED: carried) == .empty)
    #expect(compose(nil, carriedAED: carried, now: 100 + VisionOverlay.maxCameraAge + 0.01) == .empty)
    #expect(compose(nil) == .empty)
    #expect(compose(.padZones, carriedAED: carried) == .empty)
    #expect(compose(.chestCenter, carriedAED: carried) == .empty)
    #expect(compose(.injurySite, carriedAED: carried).aedArrow == nil)
}

// MARK: - A tap to a world ray

/// The transform crops the image, so a tap can't be read as a fraction of it.
@Test func aTapGoesBackThroughACroppedMappingToTheRayThroughThatPoint() throws {
    let pose = cameraPose(transform(rotationY: 25, position: [1, 1.2, 0.5]))
    let world = pose.position + (pose.transform * SIMD4<Float>(0.25, -0.1, -2, 0)).xyz
    guard case let .inFront(image) = pose.project(world) else {
        Issue.record("the point should be in front")
        return
    }
    let screen = portraitMapping.screenPoint(fromImage: image)
    #expect((0...393).contains(screen.x) && (0...852).contains(screen.y), "\(screen)")

    let back = try #require(portraitMapping.imagePoint(fromScreen: screen))
    #expect(isClose(back, image, 1e-5))

    let ray = pose.ray(throughImagePoint: back)
    let along = simd_dot(world - ray.origin, ray.direction)
    #expect(isClose(ray.origin + ray.direction * along, world, 1e-2))

    let uncropped = CaptureRotation.right.captureNormalized(fromDisplay: [screen.x / 393, screen.y / 852])
    #expect(!isClose(uncropped, image, 0.01), "this is what assuming no crop would have got")
}

@Test func aMappingThatCantBeInvertedPlacesNothing() {
    let flat = DisplayMapping(imageToView: CGAffineTransform(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0), viewSize: CGSize(width: 393, height: 852), imageAspect: 4.0 / 3)
    #expect(flat.imagePoint(fromScreen: tap) == nil)
    let noView = DisplayMapping(imageToView: portraitTransform, viewSize: .zero, imageAspect: 4.0 / 3)
    #expect(noView.imagePoint(fromScreen: tap) == nil)
}

// MARK: - Placing the pin

private final class Raycasts: Sendable {
    let count = Mutex(0)
    var made: Int { count.withLock { $0 } }
}

private func countingDriver(_ raycasts: Raycasts, hit: @escaping @Sendable (WorldRay) -> SIMD3<Float>? = wall) -> FakeDriver {
    FakeDriver(surface: { ray in
        raycasts.count.withLock { $0 += 1 }
        return hit(ray)
    })
}

@Test func aTapPlacesThePinWhereItsRayMeetsASurface() async throws {
    let clock = TestClock()
    let session = makeSession(clock: clock, driver: FakeDriver(surface: wall))
    session.apply(.overlay(.injurySite))
    let pose = cameraPose(transform(position: [0, 1.2, 0]))
    await step(session, pose: pose)
    #expect(session.overlay() == VisionOverlay(showsInjuryHint: true))

    #expect(await session.placeInjuryPin(atViewPoint: tap) == .placed)
    let image = try #require(portraitMapping.imagePoint(fromScreen: tap))
    let expected = try #require(wall(pose.ray(throughImagePoint: image)))
    #expect(session.overlay() == VisionOverlay(
        injuryPin: portraitMapping.pin(at: expected, camera: pose),
        zones: [try #require(portraitMapping.pressRing(at: expected, camera: pose))]
    ))
    let pin = try #require(session.overlay().injuryPin)
    #expect(pin.isOnScreen)
    #expect(abs(pin.position.x - tap.x / 393) < 1e-3 && abs(pin.position.y - tap.y / 852) < 1e-3, "it lands under the finger")

    let moved = cameraPose(transform(rotationY: 30, position: [1, 1.2, 0]))
    await step(session, pose: moved)
    #expect(session.overlay().injuryPin == portraitMapping.pin(at: expected, camera: moved), "held in the world, not on the screen")
}

@Test func aSecondTapMovesThePinAndRestartsItsTime() async throws {
    let clock = TestClock()
    let session = makeSession(clock: clock, driver: FakeDriver(surface: wall))
    session.apply(.overlay(.injurySite))
    await step(session)
    #expect(await session.placeInjuryPin(atViewPoint: tap) == .placed)
    let first = try #require(session.overlay().injuryPin)

    clock.advance(15)
    await step(session)
    #expect(await session.placeInjuryPin(atViewPoint: CGPoint(x: 300, y: 200)) == .placed)
    let second = try #require(session.overlay().injuryPin)
    #expect(second != first)

    clock.advance(15)
    await step(session)
    #expect(session.overlay().injuryPin == second, "30 s after the first tap, 15 s after this one")

    clock.advance(5.01)
    await step(session)
    #expect(session.overlay() == VisionOverlay(showsInjuryHint: true))

    #expect(await session.placeInjuryPin(atViewPoint: tap) == .placed, "gone isn't the end of it")
    #expect(session.overlay().injuryPin != nil)
}

@Test func aFailedRaycastPlacesNothingAndLeavesAGoodPinAlone() async throws {
    let misses = Mutex(false)
    let clock = TestClock()
    let session = makeSession(clock: clock, driver: FakeDriver(surface: { ray in misses.withLock { $0 } ? nil : wall(ray) }))
    session.apply(.overlay(.injurySite))
    await step(session)

    misses.withLock { $0 = true }
    #expect(await session.placeInjuryPin(atViewPoint: tap) == .notPlaced)
    #expect(session.overlay() == VisionOverlay(showsInjuryHint: true))

    misses.withLock { $0 = false }
    #expect(await session.placeInjuryPin(atViewPoint: tap) == .placed)
    let pin = try #require(session.overlay().injuryPin)
    misses.withLock { $0 = true }
    #expect(await session.placeInjuryPin(atViewPoint: CGPoint(x: 300, y: 200)) == .notPlaced)
    #expect(session.overlay().injuryPin == pin)
}

@Test(arguments: [TrackingQuality.limited, .notAvailable])
func poorTrackingPlacesNothingAndCastsNoRay(tracking: TrackingQuality) async {
    let raycasts = Raycasts()
    let session = makeSession(clock: TestClock(), driver: countingDriver(raycasts))
    session.apply(.overlay(.injurySite))
    await step(session, tracking: tracking)
    #expect(await session.placeInjuryPin(atViewPoint: tap) == .notPlaced)
    #expect(raycasts.made == 0)
}

@Test func aStaleOrMissingCameraPlacesNothing() async {
    let raycasts = Raycasts()
    let clock = TestClock()
    let session = makeSession(clock: clock, driver: countingDriver(raycasts))
    session.apply(.overlay(.injurySite))
    #expect(await session.placeInjuryPin(atViewPoint: tap) == .notPlaced, "no frame yet")
    await step(session)
    clock.advance(VisionOverlay.maxCameraAge + 0.01)
    #expect(await session.placeInjuryPin(atViewPoint: tap) == .notPlaced)
    #expect(raycasts.made == 0)
}

@Test(arguments: [OverlayTarget.chestCenter, .aedDevice, .padZones, nil])
func noOtherTargetTakesATap(target: OverlayTarget?) async {
    let raycasts = Raycasts()
    let session = makeSession(clock: TestClock(), driver: countingDriver(raycasts))
    session.apply(.overlay(target))
    await step(session)
    #expect(await session.placeInjuryPin(atViewPoint: tap) == .notPlaced)
    #expect(raycasts.made == 0)
}

@Test func unsupportedHardwareTakesNoTap() async {
    let session = makeSession(clock: TestClock(), driver: FakeDriver(isSupported: false))
    session.apply(.overlay(.injurySite))
    #expect(await session.placeInjuryPin(atViewPoint: tap) == .notPlaced)
    #expect(session.overlay() == .empty)
}

/// The limb steps share one pin. Leaving them takes it, or it would come back on a later step nobody tapped.
@Test func thePinLastsAcrossThePinStepsAndGoesWithThem() async throws {
    let clock = TestClock()
    let session = makeSession(clock: clock, driver: FakeDriver(surface: wall))
    session.apply(.overlay(.injurySite))
    await step(session)
    #expect(await session.placeInjuryPin(atViewPoint: tap) == .placed)
    let pin = try #require(session.overlay().injuryPin)
    session.apply(.overlay(.injurySite))
    #expect(session.overlay().injuryPin == pin, "the next limb step")

    for other in [OverlayTarget?.none, .aedDevice, .chestCenter, .padZones] {
        session.apply(.overlay(.injurySite))
        #expect(await session.placeInjuryPin(atViewPoint: tap) == .placed)
        session.apply(.overlay(other))
        session.apply(.overlay(.injurySite))
        #expect(session.overlay() == VisionOverlay(showsInjuryHint: true), "\(String(describing: other))")
    }
}

@Test func aTapStillOnItsWayWhenThePinStepsEndPlacesNothing() async {
    let driver = GatedDriver()
    let session = makeSession(clock: TestClock(), driver: driver)
    session.apply(.overlay(.injurySite))
    await step(session)
    async let result = session.placeInjuryPin(atViewPoint: tap)
    #expect(await waitUntil { driver.waiting == 1 })

    session.apply(.overlay(nil))
    driver.releaseFirst(onLimb)
    #expect(await result == .superseded)
    session.apply(.overlay(.injurySite))
    #expect(session.overlay() == VisionOverlay(showsInjuryHint: true))
}

/// A raycast that meets nothing, with a floor seen. The floor beyond still gives an AED's direction, and a
/// pin there would sit behind the limb.
private final class FloorOnlyDriver: CameraDriver {
    static let floor: SIMD3<Float> = [0, -1.3, -2]
    var isSupported: Bool { true }
    func run() {}
    func pause() {}
    func surfacePoint(along ray: WorldRay) async -> SIMD3<Float>? { Self.floor }
    func surfaceHit(along ray: WorldRay) async -> SIMD3<Float>? { nil }
}

@Test func thePinTakesNoFloorFallbackAndTheAEDStillDoes() async {
    let session = makeSession(clock: TestClock(), driver: FloorOnlyDriver(), locator: FixedLocator(box: box))
    session.apply(.overlay(.injurySite))
    await step(session)
    #expect(await session.placeInjuryPin(atViewPoint: tap) == .notPlaced)
    #expect(session.overlay() == VisionOverlay(showsInjuryHint: true))

    session.setFrameUplink(true)
    session.apply(.overlay(.aedDevice))
    session.apply(.locate(.aed))
    await step(session)
    #expect(await waitUntil { session.aedStatus == .located })
    #expect(session.objects.worldPoint(.aed) == FloorOnlyDriver.floor)
}

/// Placing the pin needs a camera pose and no pixels, so a limb step takes none until someone taps.
@Test func aPinTakesNoPixels() async throws {
    let session = makeSession(clock: TestClock(), driver: FakeDriver(surface: wall))
    session.setFrameUplink(false)
    session.apply(.overlay(.injurySite))
    let frame = session.ingest(pixels: makePixels(), pose: cameraPose(), tracking: .normal, imageToView: portraitTransform)
    #expect(frame == nil)
    #expect(await session.placeInjuryPin(atViewPoint: tap) == .placed)
}

/// Once a pin is down, pose runs on the phone to find the limb under it, and still nothing is sent.
@Test func aPlacedPinRunsLocalPoseAndSendsNothing() async throws {
    let clock = TestClock()
    let runs = Mutex(0)
    let session = VisionSession(
        locator: FixedLocator(box: nil),
        driver: FakeDriver(surface: wall),
        detect: { _, _ in
            runs.withLock { $0 += 1 }
            return []
        },
        clock: { clock.now },
        runsPump: false
    )
    session.viewportSize = portraitMapping.viewSize
    session.apply(.overlay(.injurySite))
    await step(session)
    #expect(await session.placeInjuryPin(atViewPoint: tap) == .placed)

    var sent = 0
    for _ in 0..<60 {
        session.beginFrameBurst()
        if await step(session) { sent += 1 }
        clock.advance(1.0 / 60)
    }
    #expect(sent == 0)
    let count = runs.withLock { $0 }
    #expect((8...11).contains(count), "near the pin pose runs at 10 fps at most, got \(count)")

    // With nobody tracked near it, the pin's time running out ends the pose too.
    clock.advance(VisionOverlay.pinSeconds)
    let after = session.ingest(pixels: makePixels(), pose: cameraPose(), tracking: .normal, imageToView: portraitTransform)
    #expect(after == nil)
}

// MARK: - A break in the world

@Test func aWorldResetForgetsThePin() async {
    let session = makeSession(clock: TestClock(), driver: FakeDriver(surface: wall))
    session.apply(.overlay(.injurySite))
    await step(session)
    #expect(await session.placeInjuryPin(atViewPoint: tap) == .placed)
    #expect(session.overlay().injuryPin != nil)

    session.forgetWorld()
    #expect(session.overlay() == .empty)
    await step(session)
    #expect(session.overlay() == VisionOverlay(showsInjuryHint: true), "a new world, with nothing placed")
}

@Test func stoppingAndHeatForgetThePinToo() async {
    let session = makeSession(clock: TestClock(), driver: FakeDriver(surface: wall))
    session.start()
    session.apply(.overlay(.injurySite))
    await step(session)
    #expect(await session.placeInjuryPin(atViewPoint: tap) == .placed)
    session.setThermalState(.critical)
    session.setThermalState(.fair)
    await step(session)
    #expect(session.overlay() == VisionOverlay(showsInjuryHint: true))

    #expect(await session.placeInjuryPin(atViewPoint: tap) == .placed)
    session.stop()
    await step(session)
    #expect(session.overlay() == VisionOverlay(showsInjuryHint: true))
}

/// Answers each raycast only when told, the way a busy delegate queue does.
private final class GatedDriver: CameraDriver {
    private let waiters = Mutex<[CheckedContinuation<SIMD3<Float>?, Never>]>([])
    var isSupported: Bool { true }
    func run() {}
    func pause() {}
    func surfacePoint(along ray: WorldRay) async -> SIMD3<Float>? {
        await withCheckedContinuation { continuation in waiters.withLock { $0.append(continuation) } }
    }
    var waiting: Int { waiters.withLock { $0.count } }
    func releaseFirst(_ point: SIMD3<Float>?) {
        waiters.withLock { $0.removeFirst() }.resume(returning: point)
    }
}

@Test func anAnswerFromBeforeAWorldResetIsDropped() async {
    let driver = GatedDriver()
    let session = makeSession(clock: TestClock(), driver: driver)
    session.apply(.overlay(.injurySite))
    await step(session)
    async let result = session.placeInjuryPin(atViewPoint: tap)
    #expect(await waitUntil { driver.waiting == 1 })

    session.forgetWorld()
    driver.releaseFirst(onLimb)
    #expect(await result == .superseded)
    await step(session)
    #expect(session.overlay() == VisionOverlay(showsInjuryHint: true))
}

/// The frame passed its last check and the world reset before the locate began, so its ray is from the old
/// world. Without the id taken under the check's lock, this lands as `located` most runs.
@Test func aWorldResetJustAfterAFrameClearsVoidsItsLocate() async throws {
    let locator = GatedLocator()
    let session = makeSession(clock: TestClock(), driver: FakeDriver(surface: wall), locator: locator)
    session.setFrameUplink(true)
    session.apply(.locate(.aed))
    await step(session)
    session.forgetWorld()
    #expect(await waitUntil { locator.calls == 1 })
    locator.release(box)
    try await Task.sleep(for: .milliseconds(50))
    #expect(session.objects.worldPoint(.aed) == nil)
    #expect(session.aedStatus == .idle)
}

@Test func theLastTapWinsHoweverTheAnswersArrive() async throws {
    let driver = GatedDriver()
    let session = makeSession(clock: TestClock(), driver: driver)
    session.apply(.overlay(.injurySite))
    await step(session)
    async let first = session.placeInjuryPin(atViewPoint: tap)
    #expect(await waitUntil { driver.waiting == 1 })
    async let second = session.placeInjuryPin(atViewPoint: CGPoint(x: 300, y: 200))
    #expect(await waitUntil { driver.waiting == 2 })

    driver.releaseFirst([0, 0, -1])
    #expect(await first == .superseded)
    #expect(session.overlay().injuryPin == nil)
    driver.releaseFirst(onLimb)
    #expect(await second == .placed)
    #expect(session.overlay().injuryPin == portraitMapping.pin(at: onLimb, camera: cameraPose()))
}

// MARK: - The AED, through the real engine

private func mergedBundle() throws -> ProtocolBundle {
    let clinical = repoRoot().appendingPathComponent("clinical")
    let core = try coreBundle()
    return core.merging(
        modules: ScenarioModule.manifest.map { id in
            ModuleSource(id: id, data: try? Data(contentsOf: clinical.appendingPathComponent("modules/\(id).json")))
        },
        pack: try? Data(contentsOf: clinical.appendingPathComponent("\(KnowledgePack.id).json"))
    )
}

private func coreBundle() throws -> ProtocolBundle {
    let clinical = repoRoot().appendingPathComponent("clinical")
    return try ProtocolBundle(
        protocolData: Data(contentsOf: clinical.appendingPathComponent("adult_arrest.v1.json")),
        phrasesData: Data(contentsOf: clinical.appendingPathComponent("phrases.v1.json"))
    )
}

/// The engine and vision side by side, with effects going across the way the coordinator sends them.
private final class Rescue {
    let engine: ProtocolEngine
    let session: VisionSession
    let clock: TestClock
    private(set) var state: RescueState

    init(bundle: ProtocolBundle, clock: TestClock = TestClock(), driver: any CameraDriver = FakeDriver(surface: wall), locator: any ObjectLocating) {
        engine = ProtocolEngine(bundle: bundle)
        self.clock = clock
        session = makeSession(clock: clock, driver: driver, locator: locator)
        let start = engine.start(at: clock.now)
        state = start.state
        start.effects.forEach(session.apply)
    }

    func tap(_ actions: HumanAction...) {
        for action in actions {
            let result = engine.reduce(state, .human(action), at: clock.now)
            state = result.state
            result.effects.forEach(session.apply)
        }
    }

    /// One tick, as the coordinator's loop sends it.
    func tick(_ seconds: TimeInterval = 0.2) {
        clock.advance(seconds)
        let result = engine.reduce(state, .tick, at: clock.now)
        state = result.state
        result.effects.forEach(session.apply)
    }

    /// What the coordinator asks for on entering a scan, and what comes of it.
    func locate(until status: AEDStatus) async -> Bool {
        session.apply(.locate(.aed))
        await step(session)
        return await waitUntil { self.session.aedStatus == status }
    }

    func awakeScan() {
        tap(.yes, .triageChest, .done, .yes, .scan)
        #expect(state.stateID == "chest_scan")
    }
}

/// With the key present the locate has to run on a step whose frames go on speech alone.
@Test func aScanLocatesInAnAwakeStateAndSendsNoFrameForIt() async throws {
    let rescue = Rescue(bundle: try mergedBundle(), locator: FixedLocator(box: box))
    rescue.awakeScan()
    rescue.session.apply(.locate(.aed))
    #expect(await step(rescue.session) == false, "nobody is talking")
    #expect(await waitUntil { rescue.session.aedStatus == .located })
    await step(rescue.session)
    let point = try #require(rescue.session.objects.worldPoint(.aed))
    #expect(rescue.session.overlay() == VisionOverlay(aedArrow: portraitMapping.arrow(to: point, camera: cameraPose())))

    rescue.session.beginFrameBurst()
    #expect(await step(rescue.session) == true, "speech still sends frames")
}

@Test func anAEDFoundInAnAwakeScanIsThereAfterACollapse() async throws {
    let rescue = Rescue(bundle: try mergedBundle(), locator: FixedLocator(box: box))
    rescue.awakeScan()
    #expect(await rescue.locate(until: .located))
    let point = try #require(rescue.session.objects.worldPoint(.aed))

    rescue.tap(.patientUnresponsive)
    #expect(rescue.state.stateID == "intake_breathing")
    await step(rescue.session)
    #expect(rescue.session.overlay() == .empty, "only compressions shows it")

    rescue.tap(.startCpr)
    #expect(rescue.state.stateID == "compressions")
    let pose = cameraPose(transform(rotationY: 20, position: [0.5, 1.2, 0]))
    await step(rescue.session, pose: pose)
    #expect(rescue.session.overlay() == VisionOverlay(aedArrow: portraitMapping.arrow(to: point, camera: pose)))

    await step(rescue.session, tracking: .limited)
    #expect(rescue.session.overlay() == .empty)
    await step(rescue.session)
    #expect(rescue.session.overlay().aedArrow != nil)

    rescue.tap(.aedHere)
    #expect(rescue.state.stateID == "aed_on")
    await step(rescue.session)
    #expect(rescue.session.overlay() == .empty, "it's here, so it's no use")

    rescue.tap(.emsArrived, .resumeCpr)
    #expect(rescue.state.stateID == "compressions")
    await step(rescue.session)
    #expect(rescue.session.overlay() == .empty, "back in compressions, it would point where the AED was")
}

/// No touch from the collapse on: the breathing question times out into the call step, which waits.
/// Tapping on through the setup steps reaches compressions, and the arrow waits until then.
@Test func theCarriedArrowWaitsOutTheSetupStepsAndNeverSitsBesideTheRing() async throws {
    let rescue = Rescue(bundle: try mergedBundle(), locator: FixedLocator(box: box))
    rescue.awakeScan()
    #expect(await rescue.locate(until: .located))
    rescue.tap(.patientUnresponsive)

    var visited: [String] = []
    // The breathing question waits for the rescuer, so they answer it.
    for _ in 0..<5 {
        rescue.tick()
        await step(rescue.session)
        #expect(rescue.session.overlay().aedArrow == nil, "\(rescue.state.stateID)")
    }
    rescue.tap(.no)
    for _ in 0..<300 where rescue.state.stateID != "position_patient" {
        rescue.tick()
        if visited.last != rescue.state.stateID { visited.append(rescue.state.stateID) }
        await step(rescue.session)
        #expect(rescue.session.overlay().aedArrow == nil, "\(rescue.state.stateID)")
    }
    #expect(rescue.state.stateID == "position_patient", "\(visited)")
    for _ in 0..<3 where rescue.state.stateID != "compressions" {
        rescue.tap(.done)
        if visited.last != rescue.state.stateID { visited.append(rescue.state.stateID) }
        await step(rescue.session)
        if rescue.state.stateID != "compressions" {
            #expect(rescue.session.overlay().aedArrow == nil, "\(rescue.state.stateID)")
        }
    }
    #expect(visited.contains("place_hands"), "\(visited)")
    #expect(rescue.state.stateID == "compressions")
    await step(rescue.session)
    #expect(rescue.session.overlay().aedArrow != nil)
    #expect(rescue.session.overlay().ring == nil)
}

@Test func anARResetForgetsTheCarriedPoint() async throws {
    let rescue = Rescue(bundle: try mergedBundle(), locator: FixedLocator(box: box))
    rescue.awakeScan()
    #expect(await rescue.locate(until: .located))
    rescue.tap(.startCpr)
    await step(rescue.session)
    #expect(rescue.session.overlay().aedArrow != nil)

    rescue.session.forgetWorld()
    await step(rescue.session)
    #expect(rescue.session.overlay() == .empty)
    #expect(rescue.session.objects.carriedPoint(.aed) == nil)
}

/// An answer can land seconds later, after the collapse that made it matter.
@Test func anAnswerStillOnItsWayFromAnAwakeScanCarries() async throws {
    let locator = GatedLocator()
    let rescue = Rescue(bundle: try mergedBundle(), locator: locator)
    rescue.awakeScan()
    rescue.session.apply(.locate(.aed))
    await step(rescue.session)
    #expect(await waitUntil { locator.calls == 1 })

    rescue.tap(.startCpr)
    locator.release(box)
    #expect(await waitUntil { rescue.session.aedStatus == .located })
    await step(rescue.session)
    #expect(rescue.session.overlay().aedArrow != nil)
}

@Test func aScanThatFoundNothingAwakeCarriesNothing() async throws {
    let locator = GatedLocator()
    let rescue = Rescue(bundle: try mergedBundle(), locator: locator)
    rescue.awakeScan()
    rescue.session.apply(.locate(.aed))
    await step(rescue.session)
    #expect(await waitUntil { locator.calls == 1 })
    locator.release(nil)
    #expect(await waitUntil { rescue.session.aedStatus == .notFound })

    rescue.tap(.startCpr)
    await step(rescue.session)
    #expect(rescue.session.overlay() == .empty)
}

/// A miss leaves the good point, and an arrest scan that finds it again moves it and keeps it carried.
@Test func anArrestScanThatFindsItAgainKeepsTheArrow() async throws {
    let locator = GatedLocator()
    let rescue = Rescue(bundle: try mergedBundle(), locator: locator)
    rescue.awakeScan()
    rescue.session.apply(.locate(.aed))
    await step(rescue.session)
    #expect(await waitUntil { locator.calls == 1 })
    locator.release(box)
    #expect(await waitUntil { rescue.session.aedStatus == .located })
    rescue.tap(.startCpr)
    await step(rescue.session)
    let before = try #require(rescue.session.overlay().aedArrow)

    rescue.tap(.scan)
    rescue.session.apply(.locate(.aed))
    await step(rescue.session)
    #expect(await waitUntil { locator.calls == 2 })
    locator.release(nil)
    #expect(await waitUntil { rescue.session.aedStatus == .notFound })
    rescue.tap(.done)
    await step(rescue.session)
    #expect(rescue.session.overlay().aedArrow == before, "a miss leaves the good point")

    let first = try #require(rescue.session.objects.worldPoint(.aed))
    rescue.tap(.scan)
    rescue.session.apply(.locate(.aed))
    await step(rescue.session, pose: cameraPose(transform(rotationY: 20, position: [0.5, 1.2, 0])))
    #expect(await waitUntil { locator.calls == 3 })
    locator.release(box)
    #expect(await waitUntil { rescue.session.aedStatus == .located })
    let second = try #require(rescue.session.objects.worldPoint(.aed))
    #expect(second != first)
    rescue.tap(.done)
    await step(rescue.session)
    #expect(rescue.session.overlay() == VisionOverlay(aedArrow: portraitMapping.arrow(to: second, camera: cameraPose())))
}

/// An arrest-only rescue looks as it always has, with the modules loaded or not.
@Test(arguments: [true, false])
func compressionsOnAnArrestOnlyRescueIsTheSameWithAndWithoutAScan(merged: Bool) async throws {
    let bundle = try merged ? mergedBundle() : coreBundle()

    let plain = Rescue(bundle: bundle, locator: FixedLocator(box: box))
    plain.tap(.startCpr)
    #expect(plain.state.stateID == "compressions")
    await step(plain.session)
    let without = plain.session.overlay()
    #expect(without == .empty)
    #expect(plain.session.objects.worldPoint(.aed) == nil)

    let scanned = Rescue(bundle: bundle, locator: FixedLocator(box: box))
    scanned.tap(.startCpr, .scan)
    #expect(scanned.state.stateID == "resource_scan")
    #expect(await scanned.locate(until: .located))
    await step(scanned.session)
    #expect(scanned.session.overlay().aedArrow != nil, "the scan's own arrow, as ever")
    scanned.tap(.done)
    #expect(scanned.state.stateID == "compressions")
    await step(scanned.session)
    #expect(scanned.session.objects.worldPoint(.aed) != nil, "the point is still known")
    #expect(scanned.session.overlay() == without)
    #expect(scanned.session.objects.carriedPoint(.aed) == nil)
}

/// A pin and an AED are different things in different stores, and each survives the other.
@Test func theAEDPointAndThePinKeepToThemselves() async throws {
    let rescue = Rescue(bundle: try mergedBundle(), locator: FixedLocator(box: box))
    rescue.awakeScan()
    #expect(await rescue.locate(until: .located))
    let point = try #require(rescue.session.objects.worldPoint(.aed))

    rescue.session.apply(.overlay(.injurySite))
    await step(rescue.session)
    #expect(rescue.session.overlay() == VisionOverlay(showsInjuryHint: true), "the AED isn't a pin")
    #expect(await rescue.session.placeInjuryPin(atViewPoint: tap) == .placed)
    #expect(rescue.session.objects.worldPoint(.aed) == point)
    #expect(rescue.session.overlay().aedArrow == nil)

    rescue.session.apply(.overlay(.aedDevice))
    #expect(rescue.session.overlay().injuryPin == nil)
    #expect(rescue.session.overlay().aedArrow != nil)
}
