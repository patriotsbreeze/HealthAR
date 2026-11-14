import CoreGraphics
import Foundation
@testable import RescueCore
import Synchronization
import Testing
import simd
@testable import RescueVision

private let aspect = 4.0 / 3
private let lying = person(center: [0.5, 0.6], axisDegrees: 0, aspect: aspect)
private let portraitTransform = portraitMapping.imageToView
private let towelBox = NormalizedBox(minX: 0.4, minY: 0.4, maxX: 0.6, maxY: 0.6)!
private let pillowBox = NormalizedBox(minX: 0.1, minY: 0.1, maxX: 0.2, maxY: 0.2)!
private func wall(_ ray: WorldRay) -> SIMD3<Float>? { ray.origin + ray.direction * 2 }

/// Who pose sees, changed by the test as it goes.
private final class Crowd: Sendable {
    private let people: Mutex<[DetectedPerson]>
    init(_ people: [DetectedPerson]) { self.people = Mutex(people) }
    var now: [DetectedPerson] { people.withLock { $0 } }
    func set(_ new: [DetectedPerson]) { people.withLock { $0 = new } }
}

private func makeSession(
    clock: TestClock,
    locator: any ObjectLocating = FixedLocator(box: nil),
    people: Crowd = Crowd([lying])
) -> VisionSession {
    let session = VisionSession(
        locator: locator,
        driver: FakeDriver(surface: wall),
        detect: { _, _ in people.now },
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
private func step(_ session: VisionSession, pose: CameraPose = cameraPose(), tracking: TrackingQuality = .normal) async -> Step {
    guard let frame = session.ingest(pixels: makePixels(), pose: pose, tracking: tracking, imageToView: portraitTransform) else { return Step() }
    return Step(wantedPixels: true, sentUplink: await session.process(frame))
}

// MARK: - Zones

@Test func theChestZoneShowsWithTheRingAlongTheTorso() async throws {
    let clock = TestClock()
    let session = makeSession(clock: clock)
    session.apply(.overlay(.chestCenter))
    await step(session)
    let overlay = session.overlay()
    let ring = try #require(overlay.ring)
    let zone = try #require(overlay.zones.first)
    #expect(overlay.zones.count == 1)
    #expect(zone.kind == .chest)
    #expect(zone.isLocked)
    #expect(abs(zone.center.x - ring.center.x) < 1e-9 && abs(zone.center.y - ring.center.y) < 1e-9)
    #expect(abs(zone.axis - portraitMapping.viewAngle(ofImageHeights: [1, 0])) < 1e-9)

    clock.advance(RingController.maxKeypointAge + 0.01)
    session.ingest(pixels: makePixels(), pose: cameraPose(), tracking: .normal, imageToView: portraitTransform)
    #expect(session.overlay().ring == nil)
    #expect(session.overlay().zones.isEmpty, "the hands and their axis go together")
}

@Test func padZonesShowNumberedAndAgeOut() async throws {
    let clock = TestClock()
    let session = makeSession(clock: clock)
    session.apply(.overlay(.padZones))
    #expect(await step(session).wantedPixels)
    let zones = session.overlay().zones
    #expect(zones.map(\.kind) == [.pad(1), .pad(2)])
    #expect(zones.allSatisfy { $0.isLocked })
    #expect(session.overlay().ring == nil, "pads draw no ring")

    clock.advance(0.3)
    session.ingest(pixels: makePixels(), pose: cameraPose(), tracking: .normal, imageToView: portraitTransform)
    #expect(session.overlay().zones.count == 2)
    clock.advance(VisionOverlay.maxZoneAge - 0.3 + 0.01)
    session.ingest(pixels: makePixels(), pose: cameraPose(), tracking: .normal, imageToView: portraitTransform)
    #expect(session.overlay() == .empty)
}

@Test func padsFromCrossedLabelsLandInTheSamePlaceButDashed() async throws {
    var crossed = lying
    swap(&crossed.leftShoulder, &crossed.rightShoulder)
    swap(&crossed.leftHip, &crossed.rightHip)
    let clock = TestClock()
    let straightSession = makeSession(clock: clock)
    let crossedSession = makeSession(clock: clock, people: Crowd([crossed]))
    for session in [straightSession, crossedSession] {
        session.apply(.overlay(.padZones))
        await step(session)
    }
    let straight = straightSession.overlay().zones
    let swapped = crossedSession.overlay().zones
    #expect(straight.map(\.kind) == swapped.map(\.kind))
    for (a, b) in zip(straight, swapped) {
        guard case let .polygon(p) = a.shape, case let .polygon(q) = b.shape else {
            Issue.record("pads are polygons")
            continue
        }
        for (x, y) in zip(p, q) { #expect(abs(x.x - y.x) < 1e-9 && abs(x.y - y.y) < 1e-9) }
    }
    #expect(straight.allSatisfy { $0.isLocked })
    #expect(swapped.allSatisfy { !$0.isLocked })
}

/// The limb under the pin lights up, and once locked it stays while pose still tracks it, after the pin's 20 s.
@Test func aLockedLimbOutlastsThePinWhileItIsTracked() async throws {
    let body = fullPerson(center: [0.5, 0.5], axisDegrees: 0, aspect: aspect)
    let people = Crowd([body])
    let clock = TestClock()
    let session = makeSession(clock: clock, people: people)
    session.apply(.overlay(.injurySite))
    await step(session)

    let elbow = body.joint(.leftElbow)!.position
    let wrist = body.joint(.leftWrist)!.position
    let tap = portraitMapping.screenPoint(fromImage: (elbow + wrist) / 2)
    #expect(await session.placeInjuryPin(atViewPoint: tap) == .placed)
    #expect(await step(session).wantedPixels)
    var overlay = session.overlay()
    #expect(overlay.zones.map(\.kind) == [.limb(.forearm), .pressRing])
    #expect(overlay.zones.first?.isLocked == true)
    #expect(overlay.injuryPin != nil)

    // Pose keeps tracking it through the pin's time, as at 10 fps it would.
    clock.advance(VisionOverlay.pinSeconds - 0.1)
    await step(session)
    clock.advance(0.1)
    #expect(await step(session).wantedPixels, "the pin is gone, the limb it chose isn't")
    overlay = session.overlay()
    #expect(overlay.injuryPin == nil)
    #expect(overlay.showsInjuryHint)
    #expect(overlay.zones.map(\.kind) == [.limb(.forearm)])

    people.set([])
    for _ in 0..<8 {
        clock.advance(0.1)
        await step(session)
    }
    #expect(await !step(session).wantedPixels, "no longer tracked, so pose stops")
    clock.advance(0.5)
    #expect(session.overlay() == VisionOverlay(showsInjuryHint: true))
}

@Test func anUnlockedLimbGoesWithThePin() async throws {
    let body = fullPerson(center: [0.5, 0.5], axisDegrees: 0, limbConfidence: 0.4, aspect: aspect)
    let clock = TestClock()
    let session = makeSession(clock: clock, people: Crowd([body]))
    session.apply(.overlay(.injurySite))
    await step(session)
    let tap = portraitMapping.screenPoint(fromImage: (body.joint(.leftElbow)!.position + body.joint(.leftWrist)!.position) / 2)
    #expect(await session.placeInjuryPin(atViewPoint: tap) == .placed)
    await step(session)
    #expect(session.overlay().zones.first.map { $0.kind == .limb(.forearm) && !$0.isLocked } == true)

    clock.advance(VisionOverlay.pinSeconds)
    #expect(await !step(session).wantedPixels)
}

@Test func leavingTheLimbStepsLetsGoOfTheLimb() async throws {
    let body = fullPerson(center: [0.5, 0.5], axisDegrees: 0, aspect: aspect)
    let session = makeSession(clock: TestClock(), people: Crowd([body]))
    session.apply(.overlay(.injurySite))
    await step(session)
    let tap = portraitMapping.screenPoint(fromImage: (body.joint(.leftElbow)!.position + body.joint(.leftWrist)!.position) / 2)
    #expect(await session.placeInjuryPin(atViewPoint: tap) == .placed)
    await step(session)
    #expect(session.pose.holdsLimb)

    session.apply(.overlay(nil))
    session.apply(.overlay(.injurySite))
    #expect(!session.pose.holdsLimb)
    #expect(await !step(session).wantedPixels, "a later limb step starts with no pixels again")
}

// MARK: - Items

/// Locates on a frozen frame with the uplink closed, as a limb step does.
private func locate(_ session: VisionSession, _ materials: Set<Material>, pose: CameraPose = cameraPose()) async -> Bool {
    session.requestLocate(materials)
    await step(session, pose: pose)
    return await waitUntil { materials.allSatisfy { session.locateStatus($0) != .locating } }
}

@Test func anItemShowsOnlyWhenWantedAndSeenTwice() async throws {
    let clock = TestClock()
    let session = makeSession(clock: clock, locator: MultiLocator([.towel: towelBox]))
    session.apply(.overlay(.injurySite))
    session.setLocateOpen(true)
    session.setWantedMaterials([.towel])

    #expect(await locate(session, [.towel]))
    #expect(session.locateStatus(.towel) == .located)
    #expect(session.sightings(of: .towel) == 1)
    #expect(session.overlay().items.isEmpty, "one look can be a wrong label")

    #expect(await locate(session, [.towel]))
    #expect(session.sightings(of: .towel) == 2)
    let item = try #require(session.overlay().items.first)
    #expect(item.material == .towel)
    #expect(item.isOnScreen)
    let box = try #require(item.box)
    #expect(box.contains(item.position))
    #expect(box.width > 0 && box.height > 0)

    session.setWantedMaterials([.pillow])
    #expect(session.overlay().items.isEmpty, "only what the step uses")
    session.setWantedMaterials([.towel])
    session.apply(.overlay(.injurySite))
    #expect(session.overlay().items.isEmpty, "a new step says again what it wants")

    session.setWantedMaterials([.towel])
    #expect(session.overlay().items.count == 1)
    await step(session, tracking: .limited)
    #expect(session.overlay().items.isEmpty, "a world point needs tracking")
    clock.advance(ObjectLocator.movableSeconds)
    await step(session)
    #expect(session.overlay().items.isEmpty, "it may have been picked up")
    #expect(session.locateStatus(.towel) == .idle)
}

@Test func theAEDIsNeverAnItem() async throws {
    let session = makeSession(clock: TestClock(), locator: FixedLocator(box: towelBox))
    session.setLocateOpen(true)
    session.setWantedMaterials([.aed])
    #expect(await locate(session, [.aed]))
    #expect(await locate(session, [.aed]))
    #expect(session.overlay().items.isEmpty, "it has its own arrow")
}

@Test func anItemBehindThePhoneIsOffScreenWithAWayToTurn() async throws {
    let session = makeSession(clock: TestClock(), locator: MultiLocator([.pillow: pillowBox]))
    session.apply(.overlay(.injurySite))
    session.setLocateOpen(true)
    #expect(await locate(session, [.pillow]))
    #expect(await locate(session, [.pillow]))
    session.setWantedMaterials([.pillow])

    let turned = cameraPose(transform(rotationY: 180))
    await step(session, pose: turned)
    let item = try #require(session.overlay().items.first)
    #expect(!item.isOnScreen)
    #expect(item.box == nil)
    #expect((0...1).contains(item.position.x) && (0...1).contains(item.position.y))
}

// MARK: - The locate gate

/// A step may find its materials on frozen frames without streaming anything to the model.
@Test func theLocateGateSendsFrozenFramesToTheLocatorAndNothingUpstream() async throws {
    let clock = TestClock()
    let locator = MultiLocator([.towel: towelBox])
    let session = makeSession(clock: clock, locator: locator)
    session.setLocateOpen(true)
    session.beginFrameBurst()
    session.requestLocate(.towel)
    let first = await step(session)
    #expect(first.wantedPixels)
    #expect(!first.sentUplink)
    #expect(await waitUntil { locator.calls.count == 1 })

    var sent = 0
    for _ in 0..<40 {
        session.beginFrameBurst()
        if await step(session).sentUplink { sent += 1 }
        clock.advance(0.25)
    }
    #expect(sent == 0)
}

@Test func closingTheLocateGateCancelsAPendingLocate() async throws {
    let locator = MultiLocator([.towel: towelBox])
    let session = makeSession(clock: TestClock(), locator: locator)
    session.setLocateOpen(true)
    session.requestLocate(.towel)
    session.setLocateOpen(false)
    #expect(await !step(session).wantedPixels)
    session.setLocateOpen(true)
    await step(session)
    try await Task.sleep(for: .milliseconds(50))
    #expect(locator.calls.isEmpty)
}

/// A policy without `frameLocate`, as on a call or on a step that doesn't allow it, shuts that door.
@Test func aPolicyChangeClosesTheLocateGate() async throws {
    let locator = MultiLocator([.towel: towelBox])
    let session = makeSession(clock: TestClock(), locator: locator)
    session.setLocateOpen(true)
    session.apply(.policyChanged(RuntimePolicy(modelSpeechOpen: false, micUplink: false, frameUplink: false, audioMode: .playbackOnly)))
    session.requestLocate(.towel)
    #expect(await !step(session).wantedPixels)
    try await Task.sleep(for: .milliseconds(50))
    #expect(locator.calls.isEmpty)
}

/// A towel still waiting for good tracking when a collapse takes the rescue from a limb step to the
/// arrest intake. The intake opens the uplink and closes the locate gate, and the towel isn't looked
/// for there: only limb steps locate materials.
@Test func aPendingMaterialDoesNotRideTheUplinkOntoTheArrestPath() async throws {
    let locator = MultiLocator([.towel: towelBox])
    let session = makeSession(clock: TestClock(), locator: locator)
    session.apply(.overlay(.injurySite))
    session.setLocateOpen(true)
    session.requestLocate([.towel, .pillow])
    #expect(await step(session, tracking: .limited).wantedPixels, "the phone is moving, so it waits")

    session.apply(.overlay(nil))
    var intake = RuntimePolicy(modelSpeechOpen: true, micUplink: true, frameUplink: true, audioMode: .full)
    intake.frameLocate = false
    session.apply(.policyChanged(intake))
    await step(session)
    session.requestLocate(.gloves)
    await step(session)
    try await Task.sleep(for: .milliseconds(50))
    #expect(locator.calls.isEmpty)
    #expect(session.locateStatus(.towel) == .idle)
}

/// The AED's own scan still goes on the uplink alone, as it always has.
@Test func theAEDStillLocatesOnTheUplinkAlone() async throws {
    let locator = MultiLocator([.aed: towelBox])
    let session = makeSession(clock: TestClock(), locator: locator)
    var scan = RuntimePolicy(modelSpeechOpen: true, micUplink: true, frameUplink: true, audioMode: .full)
    scan.frameLocate = false
    session.apply(.policyChanged(scan))
    session.requestLocate([.aed, .towel])
    await step(session)
    #expect(await waitUntil { locator.calls.count == 1 })
    #expect(locator.calls == [[.aed]])
}

/// The step's permission opens it, and only frozen frames to the locator go through.
@Test func aPolicyWithFrameLocateOpensTheLocateGate() async throws {
    let locator = MultiLocator([.towel: towelBox])
    let session = makeSession(clock: TestClock(), locator: locator)
    var policy = RuntimePolicy(modelSpeechOpen: false, micUplink: true, frameUplink: false, audioMode: .full)
    policy.frameLocate = true
    session.apply(.policyChanged(policy))
    session.requestLocate(.towel)
    let first = await step(session)
    #expect(first.wantedPixels)
    #expect(!first.sentUplink)
    #expect(await waitUntil { locator.calls.count == 1 })
}

/// The cues follow the overlay on every entry, so each step says again what gets a callout.
@Test func aStepsCuesChooseItsCallouts() async throws {
    let session = makeSession(clock: TestClock(), locator: MultiLocator([.towel: towelBox]))
    session.apply(.overlay(.injurySite))
    session.setLocateOpen(true)
    #expect(await locate(session, [.towel]))
    #expect(await locate(session, [.towel]))
    #expect(session.overlay().items.isEmpty, "nothing has asked for it yet")

    session.apply(.cues([Cue(phrase: "limb_support", material: .towel, body: .injuredLimb, placement: .under, callout: "Pad under · Towel")]))
    #expect(session.overlay().items.map(\.material) == [.towel])

    session.apply(.overlay(.injurySite))
    session.apply(.cues([]))
    #expect(session.overlay().items.isEmpty, "a step with no cues points at nothing")
}

@Test func closingTheLocateGateDuringEncodingVoidsTheLocate() async throws {
    let locator = MultiLocator([.towel: towelBox])
    let closing = Mutex<VisionSession?>(nil)
    let session = VisionSession(
        locator: locator,
        driver: FakeDriver(surface: wall),
        detect: { _, _ in [] },
        clock: { 100 },
        runsPump: false,
        encode: { _, _ in
            closing.withLock { $0?.setLocateOpen(false) }
            return Data([0xFF, 0xD8])
        }
    )
    closing.withLock { $0 = session }
    defer { closing.withLock { $0 = nil } }
    session.setLocateOpen(true)
    session.requestLocate(.towel)
    let frame = try #require(session.ingest(pixels: makePixels(), pose: cameraPose(), tracking: .normal, imageToView: nil))
    #expect(await session.process(frame) == false)
    try await Task.sleep(for: .milliseconds(50))
    #expect(locator.calls.isEmpty)
}

@Test func materialsAskedForTogetherGoInOneCall() async throws {
    let locator = MultiLocator([.towel: towelBox, .pillow: pillowBox])
    let session = makeSession(clock: TestClock(), locator: locator)
    session.setLocateOpen(true)
    session.requestLocate(.pillow)
    session.requestLocate([.towel, .gloves])
    await step(session)
    #expect(await waitUntil { session.locateStatus(.gloves) == .notFound })
    #expect(locator.calls == [[.towel, .pillow, .gloves]])
    #expect(session.locateStatus(.towel) == .located)
    #expect(session.locateStatus(.pillow) == .located)
}

@Test func aMaterialAlreadyBeingLookedForIsNotAskedAgain() async throws {
    let locator = GatedLocator()
    let session = makeSession(clock: TestClock(), locator: locator)
    session.setLocateOpen(true)
    session.requestLocate(.towel)
    await step(session)
    #expect(await waitUntil { locator.calls == 1 })
    #expect(session.locateStatus(.towel) == .locating)

    session.requestLocate(.towel)
    await step(session)
    try await Task.sleep(for: .milliseconds(50))
    #expect(locator.calls == 1, "the one in flight answers for itself")
    locator.release(towelBox)
    #expect(await waitUntil { session.locateStatus(.towel) == .located })

    session.requestLocate(.towel)
    await step(session)
    #expect(await waitUntil { locator.calls == 2 })
    locator.release(nil)
}

@Test func aWorldResetForgetsEveryMaterial() async throws {
    let session = makeSession(clock: TestClock(), locator: FixedLocator(box: towelBox))
    session.setLocateOpen(true)
    #expect(await locate(session, [.towel, .pillow, .aed]))
    #expect(session.locateStatus(.pillow) == .located)
    session.forgetWorld()
    for material in Material.allCases {
        #expect(session.locateStatus(material) == .idle)
        #expect(session.sightings(of: material) == 0)
    }
    #expect(session.objects.worldPoint(.aed) == nil)
}


@Test func jointDotsFollowDisplayMappingAndExpireWithThePose() async {
    let clock = TestClock()
    let session = makeSession(clock: clock)
    session.apply(.overlay(.padZones))
    await step(session)
    let expected = lying.visibleJoints.map { portraitMapping.viewPoint(fromImage: $0) }
    #expect(!expected.isEmpty)
    #expect(session.overlay().joints == expected)

    clock.advance(VisionOverlay.maxZoneAge + 0.01)
    session.ingest(pixels: makePixels(), pose: cameraPose(), tracking: .normal, imageToView: portraitTransform)
    #expect(session.overlay().joints.isEmpty)
}

@Test func jointDotsExcludeEstimatedFaintAndInvalidJoints() {
    var body = lying
    body.torsoEstimated = true
    body.extras = [
        .leftWrist: .init(position: [0.2, 0.3], confidence: 0.9),
        .rightWrist: .init(position: [0.7, 0.8], confidence: 0.2),
        .leftAnkle: .init(position: [.nan, 0.5], confidence: 1),
        .rightAnkle: .init(position: [1.1, 0.5], confidence: 1),
    ]
    #expect(body.visibleJoints == [body.leftShoulder.position, [0.2, 0.3], body.rightShoulder.position])
}
