import Testing
import Vision
import simd
@testable import RescueVision

private func joint(_ x: Double, _ y: Double, _ confidence: Double = 0.9) -> DetectedPerson.Joint {
    DetectedPerson.Joint(position: [x, y], confidence: confidence)
}

/// Vision's joint names aren't CaseIterable, so the 19 are listed here by hand, in its order.
@Test func everyVisionJointMapsToItsOwnName() {
    let vision: [HumanBodyPoseObservation.JointName] = [
        .leftEar, .leftEye, .rightEar, .rightEye, .neck, .nose,
        .leftShoulder, .leftElbow, .leftWrist, .rightShoulder, .rightElbow, .rightWrist,
        .root, .leftHip, .leftKnee, .leftAnkle, .rightHip, .rightKnee, .rightAnkle,
    ]
    let ours: [BodyJoint] = [
        .leftEar, .leftEye, .rightEar, .rightEye, .neck, .nose,
        .leftShoulder, .leftElbow, .leftWrist, .rightShoulder, .rightElbow, .rightWrist,
        .root, .leftHip, .leftKnee, .leftAnkle, .rightHip, .rightKnee, .rightAnkle,
    ]
    #expect(vision.compactMap { BodyJoint($0) } == ours)
    #expect(Set(ours) == Set(BodyJoint.allCases))
    #expect(ours.count == 19)
}

@Test func theFourJointInitStillBuildsAWholeTorso() {
    let body = person(axisDegrees: 0)
    #expect(!body.torsoEstimated)
    #expect(body.extras.isEmpty)
    #expect(body.joint(.leftHip) == body.leftHip)
}

@Test func jointsWithHipsBuildAMeasuredTorso() throws {
    let body = try #require(DetectedPerson(joints: [
        .leftShoulder: joint(0.4, 0.3), .rightShoulder: joint(0.6, 0.3),
        .leftHip: joint(0.42, 0.7), .rightHip: joint(0.58, 0.7),
        .nose: joint(0.5, 0.2), .leftElbow: joint(0.35, 0.5),
    ], imageAspect: 1))
    #expect(!body.torsoEstimated)
    #expect(Set(body.extras.keys) == [.nose, .leftElbow], "the torso joints aren't kept twice")
    #expect(body.joint(.leftElbow) == joint(0.35, 0.5))
    #expect(body.joint(.rightWrist) == nil)
}

@Test func aTorsoOnlyManikinGetsHipsFromItsHeadAndShoulders() throws {
    let body = try #require(DetectedPerson(joints: [
        .leftShoulder: joint(0.4, 0.3, 0.8), .rightShoulder: joint(0.6, 0.3),
        .nose: joint(0.5, 0.2, 0.7),
    ], imageAspect: 1))
    #expect(body.torsoEstimated)
    // Head to shoulders runs down the image, and the hips are 1.25 shoulder widths on.
    #expect(isClose(body.leftHip.position, [0.5 - 0.1 * 0.8, 0.3 + 0.25]))
    #expect(isClose(body.rightHip.position, [0.5 + 0.1 * 0.8, 0.3 + 0.25]))
    #expect(body.leftHip.confidence == 0.7, "no surer than what it came from")
    #expect(body.joint(.leftHip) == nil, "an estimated hip anchors no thigh")
}

@Test func eyesOrEarsStandInForAMissingNose() throws {
    let body = try #require(DetectedPerson(joints: [
        .leftShoulder: joint(0.3, 0.4), .rightShoulder: joint(0.3, 0.6),
        .leftEar: joint(0.2, 0.45), .rightEar: joint(0.2, 0.55),
    ], imageAspect: 1))
    #expect(body.torsoEstimated)
    #expect(body.leftHip.position.x > 0.5, "the head is to the left, so the hips go right")
}

@Test func faintJointsCountAsUnseen() throws {
    let faintHips = try #require(DetectedPerson(joints: [
        .leftShoulder: joint(0.4, 0.3), .rightShoulder: joint(0.6, 0.3),
        .leftHip: joint(0.42, 0.7, 0.05), .rightHip: joint(0.58, 0.7, 0.05),
        .nose: joint(0.5, 0.2),
    ], imageAspect: 1))
    #expect(faintHips.torsoEstimated)
    #expect(faintHips.extras[.leftHip] == nil)

    #expect(DetectedPerson(joints: [
        .leftShoulder: joint(0.4, 0.3), .rightShoulder: joint(0.6, 0.3), .nose: joint(0.5, 0.2, 0.05),
    ], imageAspect: 1) == nil)
}

/// Hips Vision only half sees, as under a blanket or at the edge of a close chest frame, would be
/// turned down for low confidence. They give way to the head-and-shoulders estimate, so faint hips
/// never do worse than none.
@Test func faintHipsGiveWayToTheEstimate() throws {
    let faint = try #require(DetectedPerson(joints: [
        .leftShoulder: joint(0.4, 0.3), .rightShoulder: joint(0.6, 0.3),
        .leftHip: joint(0.42, 0.7, 0.15), .rightHip: joint(0.58, 0.7, 0.15),
        .nose: joint(0.5, 0.2),
    ], imageAspect: 1))
    #expect(faint.torsoEstimated)
    #expect(faint.lowestConfidence >= PatientSelector().minConfidence)
    #expect(faint.extras[.leftHip] == nil)

    let sure = try #require(DetectedPerson(joints: [
        .leftShoulder: joint(0.4, 0.3), .rightShoulder: joint(0.6, 0.3),
        .leftHip: joint(0.42, 0.7, 0.3), .rightHip: joint(0.58, 0.7, 0.3),
        .nose: joint(0.5, 0.2),
    ], imageAspect: 1))
    #expect(!sure.torsoEstimated, "hips the selector takes are measured")

    let headless = try #require(DetectedPerson(joints: [
        .leftShoulder: joint(0.4, 0.3), .rightShoulder: joint(0.6, 0.3),
        .leftHip: joint(0.42, 0.7, 0.15), .rightHip: joint(0.58, 0.7, 0.15),
    ], imageAspect: 1))
    #expect(!headless.torsoEstimated, "with no head the faint hips are all there is")
    #expect(headless.lowestConfidence == 0.15)
}

/// The same faint hips on a lying body still give the ring and dashed zones.
@Test func faintHipsStillGiveTheRingAndDashedZones() async throws {
    let manikin = try #require(DetectedPerson(joints: [
        .leftShoulder: joint(0.3, 0.4), .rightShoulder: joint(0.3, 0.6),
        .leftHip: joint(0.7, 0.42, 0.15), .rightHip: joint(0.7, 0.58, 0.15),
        .nose: joint(0.2, 0.5),
    ], imageAspect: 1))
    let worker = PoseWorker { _, _ in [manikin] }
    let record = FrameRecord(
        id: 1,
        timestamp: 10,
        pose: CameraPose(transform: matrix_identity_float4x4, intrinsics: testIntrinsics, imageResolution: [1000, 1000]),
        tracking: .normal
    )
    await worker.process(CapturedFrame(id: 1, pixels: makePixels()), record: record)
    let regions = try #require(worker.latestPose?.regions)
    #expect(regions.chest != nil)
    #expect(!regions.chestLocked && !regions.padsLocked)
}

@Test func noDirectionOrNoShouldersIsNoPerson() {
    #expect(DetectedPerson(joints: [
        .leftShoulder: joint(0.4, 0.3), .rightShoulder: joint(0.6, 0.3), .nose: joint(0.5, 0.31),
    ], imageAspect: 1) == nil, "a head on the shoulder line says nothing about which way the body runs")
    #expect(DetectedPerson(joints: [
        .leftShoulder: joint(0.4, 0.3), .leftHip: joint(0.42, 0.7), .rightHip: joint(0.58, 0.7), .nose: joint(0.5, 0.2),
    ], imageAspect: 1) == nil)
    #expect(DetectedPerson(joints: [:], imageAspect: 1) == nil)
}

/// The estimate gets a manikin a ring and zones, drawn dashed so nobody takes them as measured.
@Test func anEstimatedTorsoStillGivesTheRingAndDashedZones() async throws {
    let manikin = try #require(DetectedPerson(joints: [
        .leftShoulder: joint(0.3, 0.4), .rightShoulder: joint(0.3, 0.6), .nose: joint(0.2, 0.5),
    ], imageAspect: 1))
    let worker = PoseWorker { _, _ in [manikin] }
    let record = FrameRecord(
        id: 1,
        timestamp: 10,
        pose: CameraPose(transform: matrix_identity_float4x4, intrinsics: testIntrinsics, imageResolution: [1000, 1000]),
        tracking: .normal
    )
    await worker.process(CapturedFrame(id: 1, pixels: makePixels()), record: record)
    #expect(worker.latest != nil)
    let regions = try #require(worker.latestPose?.regions)
    #expect(regions.chest != nil)
    #expect(!regions.chestLocked)
    #expect(regions.padOne != nil)
    #expect(!regions.padsLocked)
}
