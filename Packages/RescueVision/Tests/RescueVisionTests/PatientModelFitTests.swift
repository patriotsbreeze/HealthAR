import CoreGraphics
import Foundation
import Testing
import simd
@testable import RescueVision

private func fixture() -> (camera: CameraPose, depth: BodyDepth, person: DetectedPerson) {
    let camera = cameraPose(lookingStraightDown)
    func joint(_ world: SIMD3<Float>) -> DetectedPerson.Joint {
        guard case let .inFront(image) = camera.project(world) else { fatalError("fixture behind camera") }
        return .init(position: image, confidence: 0.9)
    }
    return (
        camera,
        BodyDepth(width: 64, height: 48, metres: Array(repeating: 1.5, count: 64 * 48), confidence: Array(repeating: 2, count: 64 * 48)),
        DetectedPerson(
            leftShoulder: joint([-0.2, 0, -0.25]), rightShoulder: joint([0.2, 0, -0.25]),
            leftHip: joint([-0.12, 0, 0.33]), rightHip: joint([0.12, 0, 0.33])
        )
    )
}

@Test func sceneDepthUnprojectsUsingTheCapturedCameraAndRejectsBadSamples() throws {
    let f = fixture()
    let center = try #require(f.depth.worldPoint([0.5, 0.5], camera: f.camera))
    #expect(simd_distance(center, [0, 0, 0]) < 0.00001)
    var low = f.depth
    low.confidence = Array(repeating: 0, count: low.metres.count)
    #expect(low.sample([0.5, 0.5]) == nil)
    var invalid = f.depth
    invalid.metres = Array(repeating: .nan, count: invalid.metres.count)
    #expect(invalid.sample([0.5, 0.5]) == nil)
    #expect(f.depth.sample([-0.1, 0.5]) == nil)
    #expect(f.depth.sample([.nan, 0.5]) == nil)
    #expect(f.depth.sample([0, 0]) == nil)
}

@Test func depthAtTheEdgeOfBodyAndFloorDoesNotFit() {
    var depth = fixture().depth
    depth.metres[24 * depth.width + 32] = 2
    #expect(depth.sample([0.5, 0.5]) == nil)
}

@Test func blenderPatientTorsoFitsMeasuredShouldersAndHipsWithIndependentScales() throws {
    let f = fixture()
    let fit = try #require(PatientModelFit.fit(person: f.person, depth: f.depth, camera: f.camera))
    let shoulders = (fit.transform * SIMD4<Float>(PatientModelFit.shouldersX, PatientModelFit.bodyY, 0, 1)).xyz
    let hips = (fit.transform * SIMD4<Float>(PatientModelFit.hipsX, PatientModelFit.bodyY, 0, 1)).xyz
    #expect(simd_distance(shoulders, [0, 0, -0.25]) < 0.0001)
    #expect(simd_distance(hips, [0, 0, 0.33]) < 0.0001)
    #expect(simd_dot(fit.normal, [0, 1, 0]) > 0.99)
    #expect(!fit.showsChestEstimate, "a detected body alone must not prompt compressions")
    let expected = SIMD3<Float>(0, 0.008, -0.25 + 0.58 * Float(TorsoMap.alongTorso))
    #expect(simd_distance(fit.chest, expected) < 0.0001)
}

@Test func estimatedHipsThatSitOnTheBodyStillFit() {
    let f = fixture()
    var estimated = f.person
    estimated.torsoEstimated = true
    #expect(PatientModelFit.fit(person: estimated, depth: f.depth, camera: f.camera) != nil)
}

@Test func faintJointsAndStandingPeopleNeverProduceAFittedPatient() {
    let f = fixture()
    var faint = f.person
    faint.leftShoulder.confidence = 0.2
    #expect(PatientModelFit.fit(person: faint, depth: f.depth, camera: f.camera) == nil)
    #expect(PatientModelFit.fit(person: f.person, depth: f.depth, camera: cameraPose()) == nil)
}

@Test func stoppedCameraAndTrackingInterruptionRemoveDepthPatient() async throws {
    let f = fixture()
    let clock = TestClock()
    let session = VisionSession(
        locator: FixedLocator(box: nil), driver: FakeDriver(),
        detect: { _, _ in [f.person] }, clock: { clock.now }, runsPump: false
    )
    session.viewportSize = CGSize(width: 393, height: 852)
    session.start()
    let frame = try #require(session.ingest(pixels: makePixels(), pose: f.camera, tracking: .normal,
        imageToView: portraitMapping.imageToView, bodyDepth: f.depth))
    #expect(await !session.process(frame))
    #expect(session.patientBodyPlacement() != nil)
    #expect(session.patientBodyPlacement()?.showsChestEstimate == false)
    #expect(!session.overlay().patientIn3D, "keep flat guidance until the asset actually loads")
    session.patientModelDidLoad()
    #expect(session.overlay().patientIn3D)
    clock.advance(VisionOverlay.maxJointAge + 0.01)
    session.ingest(pixels: makePixels(), pose: f.camera, tracking: .normal,
        imageToView: portraitMapping.imageToView, bodyDepth: f.depth)
    #expect(session.patientBodyPlacement() == nil, "a fresh camera frame does not revive an old body fit")
    session.forgetWorld()
    #expect(session.patientBodyPlacement() == nil)
    session.stop()
    #expect(session.patientBodyPlacement() == nil)
}

/// One shoulder's depth landing on the floor beside the body, as with arms spread, used to tip the
/// body's chest direction and draw it rolled onto its side. Gravity sets it now.
@Test func aShoulderReadingOffTheBodyStillFitsFaceUp() throws {
    let f = fixture()
    var depth = f.depth
    let shoulder = f.person.leftShoulder.position
    let cx = Int(shoulder.x * Double(depth.width)), cy = Int(shoulder.y * Double(depth.height))
    // Just the shoulder: wider, it would reach where the chest is read too, which rightly turns down an edge.
    for y in max(0, cy - 2)...min(depth.height - 1, cy + 2) {
        for x in max(0, cx - 2)...min(depth.width - 1, cx + 2) {
            depth.metres[y * depth.width + x] = 1.62
        }
    }
    let fit = try #require(PatientModelFit.fit(person: f.person, depth: depth, camera: f.camera, requireLying: false))
    // The low shoulder pitches head-to-hips a few degrees, which is fine; it must not roll.
    #expect(simd_dot(fit.normal, [0, 1, 0]) > 0.99, "face up")
    #expect(fit.lying)
    // Its thickness runs up the world, and its width across the floor.
    let up = simd_normalize(fit.transform.columns.1.xyz), across = simd_normalize(fit.transform.columns.2.xyz)
    #expect(simd_dot(up, [0, 1, 0]) > 0.99)
    #expect(abs(across.y) < 0.001, "not rolled: its width lies level across the floor")
    #expect(simd_determinant(fit.transform) > 0, "never mirrored")
}

@Test func anUprightPersonFacesTheCamera() throws {
    // Shoulders over hips, a metre and a half in front of a level camera.
    let camera = cameraPose()
    func joint(_ world: SIMD3<Float>) -> DetectedPerson.Joint {
        guard case let .inFront(image) = camera.project(world) else { fatalError("behind camera") }
        return .init(position: image, confidence: 0.9)
    }
    let person = DetectedPerson(
        leftShoulder: joint([-0.2, 0.25, -1.5]), rightShoulder: joint([0.2, 0.25, -1.5]),
        leftHip: joint([-0.12, -0.33, -1.5]), rightHip: joint([0.12, -0.33, -1.5])
    )
    let depth = BodyDepth(width: 64, height: 48, metres: Array(repeating: 1.5, count: 64 * 48), confidence: Array(repeating: 2, count: 64 * 48))
    guard let fit = PatientModelFit.fit(person: person, depth: depth, camera: camera, requireLying: false) else { return }
    #expect(!fit.lying)
    #expect(simd_dot(fit.normal, [0, 0, 1]) > 0.9, "toward the camera")
}
