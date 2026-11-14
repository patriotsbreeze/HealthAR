import CoreGraphics
import Foundation
import RescueCore
import Testing
import RealityKit
import simd
@testable import RescueVision

/// In front of a camera at the origin looking along -z, below eye level.
private let chest = SIMD3<Float>(0, -0.8, -1.5)
private let floor = chest - SIMD3<Float>(0, GhostRescuer.chestHeight, 0)

// MARK: - Where the ghost kneels

@Test func theGhostKneelsOnTheFarSideAcrossTheBody() throws {
    let anchor = try #require(GhostAnchor(chest: chest, shoulders: chest + [0.3, 0.02, 0], camera: .zero))
    #expect(isClose(anchor.headward, [1, 0, 0]))
    #expect(isClose(anchor.side, [0, 0, -1]), "away from the camera, so it never hides the chest")
}

@Test func withNoShouldersTheBodyLiesAcrossTheView() throws {
    let anchor = try #require(GhostAnchor(chest: chest, shoulders: nil, camera: .zero))
    #expect(abs(simd_dot(anchor.headward, [0, 0, 1])) < 1e-4)
    #expect(isClose(anchor.side, [0, 0, -1]))
}

@Test func aCameraStraightAboveTheChestPlacesNoGhost() {
    #expect(GhostAnchor(chest: chest, shoulders: nil, camera: chest + [0, 1, 0]) == nil)
}

@Test func aPracticePatientLiesOnTheFloorWithItsChestAtManikinHeight() throws {
    let anchor = try #require(GhostAnchor(floor: floor, camera: .zero))
    #expect(isClose(anchor.chest, chest))
}

// MARK: - The push

@Test func thePushIsDeepestOnTheClickAndUpAtTheHalfBeat() {
    let beat = GhostRescuer.beatInterval
    #expect(isClose(GhostRescuer.push(sinceBeatStart: 0, beatInterval: beat), 1))
    #expect(isClose(GhostRescuer.push(sinceBeatStart: beat / 2, beatInterval: beat), 0))
    #expect(isClose(GhostRescuer.push(sinceBeatStart: beat * 7, beatInterval: beat), 1, 1e-9))
    #expect(GhostRescuer.push(sinceBeatStart: -1, beatInterval: beat) == 0)
}

@Test func theGhostKeepsTheMetronomesBeat() {
    #expect(isClose(GhostRescuer.beatInterval, 60.0 / 110))
}

// MARK: - The body

@Test func pressedHandsGoDownFiveCentimetresWithLockedArms() throws {
    let anchor = try #require(GhostAnchor(chest: chest, shoulders: nil, camera: .zero))
    let up = GhostRescuer.joints(anchor, push: 0)
    let down = GhostRescuer.joints(anchor, push: 1)
    let upHands = try #require(up[.hands]), downHands = try #require(down[.hands])
    #expect(isClose(upHands - downHands, [0, GhostRescuer.depth, 0]))
    // Shoulders ride down with the hands, so the arms stay the same length.
    let upShoulder = try #require(up[.leftShoulder]), downShoulder = try #require(down[.leftShoulder])
    #expect(isClose(Double(simd_distance(upShoulder, upHands)), Double(simd_distance(downShoulder, downHands)), 1e-4))
    #expect(isClose(up[.pelvis] ?? .zero, down[.pelvis] ?? .one), "it hinges at the hips")
}

@Test func theGhostKneelsBesideThePatientWithShouldersOverTheHands() throws {
    let anchor = try #require(GhostAnchor(chest: chest, shoulders: nil, camera: .zero))
    let joints = GhostRescuer.joints(anchor, push: 0)
    #expect(Set(joints.keys) == Set(GhostJoint.allCases))
    let hands = try #require(joints[.hands])
    let shoulders = (try #require(joints[.leftShoulder]) + (try #require(joints[.rightShoulder]))) / 2
    let lean = simd_length(SIMD2(shoulders.x - hands.x, shoulders.z - hands.z))
    #expect(lean < 0.05, "shoulders straight over the hands")
    #expect(shoulders.y > hands.y + 0.5)
    #expect((try #require(joints[.head])).y > shoulders.y)
    for knee in [GhostJoint.leftKnee, .rightKnee] {
        let point = try #require(joints[knee])
        #expect(simd_dot(point - chest, anchor.side) > 0.2, "on the far side")
        #expect(abs(point.y - floor.y) < 0.1, "on the floor")
    }
}

@Test func thePracticePatientLiesFaceUpUnderTheGhostsHands() throws {
    let anchor = try #require(GhostAnchor(floor: floor, camera: .zero))
    let body = PracticePatient.joints(anchor)
    #expect(Set(body.keys) == Set(PracticePatient.Joint.allCases))
    let head = try #require(body[.head]), foot = try #require(body[.leftFoot])
    #expect(simd_dot(head - chest, anchor.headward) > 0.3)
    #expect(simd_dot(foot - chest, anchor.headward) < -1)
    #expect(body.values.allSatisfy { $0.y <= chest.y }, "nothing stands up off the floor")
}

// MARK: - On screen

@Test func theGhostProjectsWithEveryBone() throws {
    let anchor = try #require(GhostAnchor(floor: floor, camera: .zero))
    let ghost = try #require(portraitMapping.ghost(anchor, push: 1, practice: true, camera: cameraPose()))
    #expect(ghost.rescuer.segments.count == GhostJoint.bones.count)
    #expect(ghost.rescuer.hands != nil)
    let patient = try #require(ghost.patient)
    #expect(patient.segments.count == PracticePatient.Joint.bones.count)
    #expect(patient.hands == nil)
    #expect(ghost.pointsPerMetre > 0)
}

@Test func aGhostFoundByPoseDrawsNoPracticePatient() throws {
    let anchor = try #require(GhostAnchor(chest: chest, shoulders: nil, camera: .zero))
    let ghost = try #require(portraitMapping.ghost(anchor, push: 0, practice: false, camera: cameraPose()))
    #expect(ghost.patient == nil)
}

@Test func aGhostBehindTheCameraDrawsNothing() throws {
    let anchor = try #require(GhostAnchor(chest: [0, -0.8, 1.5], shoulders: nil, camera: .zero))
    #expect(portraitMapping.ghost(anchor, push: 0, practice: true, camera: cameraPose()) == nil)
}

// MARK: - In a session

private func makeSession(clock: TestClock, surface: SIMD3<Float>? = floor, people: [DetectedPerson] = []) -> VisionSession {
    let session = VisionSession(
        locator: FixedLocator(box: nil),
        driver: FakeDriver(surface: { _ in surface }),
        detect: { _, _ in people },
        clock: { clock.now },
        runsPump: false
    )
    session.viewportSize = portraitMapping.viewSize
    return session
}

private func frame(_ session: VisionSession, tracking: TrackingQuality = .normal) async {
    if let captured = session.ingest(pixels: makePixels(), pose: cameraPose(), tracking: tracking, imageToView: portraitMapping.imageToView) {
        await session.process(captured)
    }
}

@Test func aPracticePatientShowsTheGhostOnTheBeatInCompressions() async throws {
    let clock = TestClock()
    let session = makeSession(clock: clock)
    session.apply(.overlay(nil))
    await frame(session)
    #expect(await session.placePracticePatient())
    #expect(session.hasPracticePatient)
    #expect(session.overlay().ghost == nil, "still until the metronome starts")

    session.setGhostBeat(on: true)
    let pressed = try #require(session.overlay().ghost)
    #expect(pressed.patient != nil)
    #expect(isClose(pressed.push, 1))

    clock.advance(GhostRescuer.beatInterval / 2)
    await frame(session)
    #expect(isClose(try #require(session.overlay().ghost).push, 0, 1e-9))

    // A repeat while it is on keeps the grid, as the metronome does.
    session.setGhostBeat(on: true)
    #expect(isClose(try #require(session.overlay().ghost).push, 0, 1e-9))

    session.setGhostBeat(on: false)
    #expect(session.overlay().ghost == nil)
}

@Test func theGhostOnlyDrawsOnAStepWithNoMarkOfItsOwn() async throws {
    let clock = TestClock()
    let session = makeSession(clock: clock)
    await frame(session)
    #expect(await session.placePracticePatient())
    session.setGhostBeat(on: true)
    session.apply(.overlay(.aedDevice))
    await frame(session)
    #expect(session.overlay().ghost == nil)
    session.apply(.overlay(nil))
    await frame(session)
    #expect(session.overlay().ghost != nil, "the anchor outlasts the steps between")
}

@Test func theGhostNeedsTrackingThatHoldsTheWorld() async throws {
    let clock = TestClock()
    let session = makeSession(clock: clock)
    session.apply(.overlay(nil))
    await frame(session)
    #expect(await session.placePracticePatient())
    session.setGhostBeat(on: true)
    await frame(session, tracking: .limited)
    #expect(session.overlay().ghost == nil)
}

@Test func noFloorPlacesNoPracticePatient() async {
    let clock = TestClock()
    let session = makeSession(clock: clock, surface: nil)
    await frame(session)
    #expect(await !session.placePracticePatient())
    #expect(!session.hasGhostAnchor)
}

@Test func noFreshCameraPlacesNoPracticePatient() async {
    let clock = TestClock()
    let session = makeSession(clock: clock)
    #expect(await !session.placePracticePatient(), "no frame yet")
    await frame(session)
    clock.advance(1)
    #expect(await !session.placePracticePatient(), "the last frame is stale")
}

@Test func forgettingTheWorldTakesTheGhostAway() async throws {
    let clock = TestClock()
    let session = makeSession(clock: clock)
    await frame(session)
    #expect(await session.placePracticePatient())
    session.forgetWorld()
    #expect(!session.hasGhostAnchor)
    #expect(!session.hasPracticePatient)
}

@Test func clearingThePracticePatientTakesItsGhostAway() async {
    let clock = TestClock()
    let session = makeSession(clock: clock)
    await frame(session)
    #expect(await session.placePracticePatient())
    session.clearPracticePatient()
    #expect(!session.hasGhostAnchor)
}

@Test func aRealChestTakesOverFromThePracticePatient() async throws {
    let clock = TestClock()
    let lying = person(center: [0.5, 0.6], axisDegrees: 0, aspect: 4.0 / 3)
    let session = makeSession(clock: clock, surface: chest, people: [lying])
    await frame(session)
    #expect(await session.placePracticePatient())
    session.apply(.overlay(.chestCenter))
    await frame(session)
    #expect(await waitUntil { !session.hasPracticePatient })
    #expect(session.hasGhostAnchor)
}

@Test func theHandsGuidePlacesTheGhostFromThePatientsChest() async throws {
    let clock = TestClock()
    let lying = person(center: [0.5, 0.6], axisDegrees: 0, aspect: 4.0 / 3)
    let session = makeSession(clock: clock, surface: chest, people: [lying])
    session.apply(.overlay(nil))
    session.beginHandsGuide()
    await frame(session)
    #expect(await waitUntil { session.hasGhostAnchor })
    #expect(!session.hasPracticePatient)

    // After the guide no pixels are wanted, and the ghost stays where it was put.
    clock.advance(VisionSession.handsGuideSeconds)
    session.setGhostBeat(on: true)
    await frame(session)
    let ghost = try #require(session.overlay().ghost)
    #expect(ghost.patient == nil)
}

// MARK: - Fitting the patient to the body found

@Test func theOutlineIsSizedToTheBodyFound() throws {
    // A manikin's shoulders 0.4 m from its hips, against the model's 0.57.
    let anchor = try #require(GhostAnchor(chest: chest, shoulders: chest + [0.1, 0, 0], hips: chest + [-0.3, 0, 0], camera: .zero))
    #expect(isClose(Double(anchor.bodyScale), 0.4 / Double(GhostAnchor.modelTorso), 1e-4))
}

@Test func anImplausibleBodySizeIsHeldToTheRange() throws {
    let huge = try #require(GhostAnchor(chest: chest, shoulders: chest + [0.5, 0, 0], hips: chest + [-1.5, 0, 0], camera: .zero))
    #expect(huge.bodyScale == GhostAnchor.bodyScales.upperBound)
    let tiny = try #require(GhostAnchor(chest: chest, shoulders: chest + [0.05, 0, 0], hips: chest + [-0.05, 0, 0], camera: .zero))
    #expect(tiny.bodyScale == GhostAnchor.bodyScales.lowerBound)
}

@Test func noHipsLeavesTheModelsOwnSize() throws {
    let anchor = try #require(GhostAnchor(chest: chest, shoulders: chest + [0.1, 0, 0], camera: .zero))
    #expect(anchor.bodyScale == 1)
    #expect(try #require(GhostAnchor(floor: floor, camera: .zero)).bodyScale == 1)
}

@Test func aBodyFoundByPoseGetsAnOutlineSizedToItAndNoFill() async throws {
    let clock = TestClock()
    let lying = person(center: [0.5, 0.6], axisDegrees: 0, aspect: 4.0 / 3)
    let session = makeSession(clock: clock, surface: chest, people: [lying])
    session.apply(.overlay(nil))
    session.beginHandsGuide()
    await frame(session)
    #expect(await waitUntil { session.hasGhostAnchor })
    session.setGhostBeat(on: true)
    let placement = try #require(session.ghostPlacement())
    #expect(!placement.practice, "the real body shows through, with a line round it")
    #expect(GhostAnchor.bodyScales.contains(placement.patientScale))
}

@MainActor
@Test func theModelHasEveryPartTheRendererLooksFor() async throws {
    let url = try #require(Bundle.module.url(forResource: "Ghost", withExtension: "usdz"))
    let root = try await Entity(contentsOf: url)
    for name in ["RescuerUpper", "RescuerLower", "Patient", "PatientOutline"] {
        #expect(root.findEntity(named: name) != nil, "\(name)")
    }
    // Metres, chest top at the origin, floor below it.
    let patient = try #require(root.findEntity(named: "Patient")).visualBounds(relativeTo: nil)
    #expect(abs(patient.max.y) < 0.03)
    #expect(abs(patient.min.y - GhostRescuer.chestHeight * -1) < 0.03)
    let outline = try #require(root.findEntity(named: "PatientOutline")).visualBounds(relativeTo: nil)
    #expect(outline.max.y > patient.max.y, "the outline sits just outside the body")
}

// MARK: - The hands, and a phone held over the chest

@Test func overTheChestTheRescuerIsAtTheBottomOfTheScreen() throws {
    let anchor = try #require(GhostAnchor(chest: chest, shoulders: nil, camera: chest + [0.02, 0.6, 0], cameraDown: [0, 0, 1]))
    #expect(isClose(anchor.side, [0, 0, 1]))
    #expect(abs(simd_dot(anchor.headward, anchor.side)) < 1e-4)
}

@Test func fromTheSideTheCamerasPositionStillDecides() throws {
    // Screen-down says otherwise, but a camera well off to one side knows which side is far.
    let anchor = try #require(GhostAnchor(chest: chest, shoulders: nil, camera: .zero, cameraDown: [1, 0, 0]))
    #expect(isClose(anchor.side, [0, 0, -1]))
}

@Test func screenDownPointsDownTheView() throws {
    let camera = CameraPose(transform: portraitLevel, intrinsics: testIntrinsics, imageResolution: [1920, 1440])
    let ahead = camera.position + SIMD3<Float>(0, 0, -2)
    guard case let .inFront(center) = camera.project(ahead),
          case let .inFront(lower) = camera.project(ahead + camera.screenDown * 0.2) else { throw CancellationError() }
    #expect(portraitMapping.viewPoint(fromImage: lower).y > portraitMapping.viewPoint(fromImage: center).y)
}

@Test func theHandsShowWhereTheStepShowsWhereHandsGo() async throws {
    let clock = TestClock()
    let lying = person(center: [0.5, 0.6], axisDegrees: 0, aspect: 4.0 / 3)
    let session = makeSession(clock: clock, surface: chest, people: [lying])
    session.apply(.overlay(.chestCenter))
    await frame(session)
    #expect(await waitUntil { session.hasGhostAnchor })
    let hands = try #require(session.handsPlacement())
    #expect(isClose(hands.transform.columns.3.xyz, chest))
    #expect(session.overlay().handsIn3D, "the flat hands give way")

    // Compressions: up for the hands guide, gone after it.
    session.apply(.overlay(nil))
    session.beginHandsGuide()
    await frame(session)
    #expect(session.handsPlacement() != nil)
    clock.advance(VisionSession.handsGuideSeconds)
    await frame(session)
    #expect(session.handsPlacement() == nil)
    #expect(!session.overlay().handsIn3D)
}

@Test func noChestPlacedKeepsTheFlatHands() async {
    let clock = TestClock()
    let lying = person(center: [0.5, 0.6], axisDegrees: 0, aspect: 4.0 / 3)
    let session = makeSession(clock: clock, surface: nil, people: [lying])
    session.apply(.overlay(.chestCenter))
    await frame(session)
    #expect(session.handsPlacement() == nil)
    #expect(!session.overlay().handsIn3D)
}

@MainActor
@Test func theHandsModelHasTheHeelOnTheChestAndFingersAway() async throws {
    let url = try #require(Bundle.module.url(forResource: "Hands", withExtension: "usdz"))
    let root = try await Entity(contentsOf: url)
    for name in ["HandLower", "HandUpper"] {
        #expect(root.findEntity(named: name) != nil, "\(name)")
    }
    let bounds = root.visualBounds(relativeTo: nil)
    #expect(bounds.min.y > -0.02, "only the lower thumb tucks against the chest")
    #expect(bounds.max.y < 0.13, "a stack of two hands, not a tower")
    #expect(bounds.min.z < -0.12, "fingers reach away from the rescuer")
    #expect(bounds.max.z < 0.06, "only a stub of wrist toward them")
    #expect(bounds.max.x - bounds.min.x < 0.22, "about a hand wide, with the lower thumb resting out to the side")
}
