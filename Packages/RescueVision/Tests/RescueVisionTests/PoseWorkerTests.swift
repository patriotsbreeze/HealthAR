import CoreGraphics
import Foundation
import Synchronization
import Testing
import Vision
@testable import RescueVision

private func record(id: UInt64 = 1, at time: Double = 10, tracking: TrackingQuality = .limited) -> FrameRecord {
    FrameRecord(id: id, timestamp: time, pose: cameraPose(), tracking: tracking)
}

private let lying = person(center: [0.5, 0.6], axisDegrees: 0, aspect: 4.0 / 3)
private let upright = person(center: [0.2, 0.4], axisDegrees: 90, aspect: 4.0 / 3)
private let frame = CapturedFrame(id: 1, pixels: makePixels())

private func worker(_ people: [DetectedPerson]) -> PoseWorker {
    PoseWorker { _, _ in people }
}

@Test func publishesTheTargetWithItsCaptureTime() async throws {
    let pose = worker([upright, lying])
    await pose.process(frame, record: record(id: 7, at: 10))
    let latest = try #require(pose.latest)
    #expect(latest.frameID == 7)
    #expect(latest.capturedAt == 10)
    #expect(isClose(latest.age(at: 10.05), 0.05))
    #expect(pose.lastNoTargetReason == nil)
}

@Test func limitedTrackingStillGivesARing() async {
    // ARKit reports limited while it initializes, and M2 wants a ring within 2 s of that.
    let pose = worker([lying])
    await pose.process(frame, record: record(tracking: .limited))
    #expect(pose.latest != nil)
}

@Test func noTrackingMeansNoGravityAndNoTarget() async {
    let pose = worker([lying])
    await pose.process(frame, record: record(tracking: .notAvailable))
    #expect(pose.latest == nil)
    #expect(pose.lastNoTargetReason == .gravityUnknown)
}

@Test func twoPeopleLyingDownAtTheStartGiveNoTarget() async {
    let pose = worker([lying, person(center: [0.5, 0.2], axisDegrees: 180, aspect: 4.0 / 3)])
    await pose.process(frame, record: record())
    #expect(pose.latest == nil)
    #expect(pose.lastNoTargetReason == .multipleCandidates)
}

/// The first one found lying down keeps the body, so someone else lying down later can't take it.
@Test func aSecondPersonLyingDownLaterDoesntTakeThePatient() async throws {
    let people = Mutex([lying])
    let pose = PoseWorker { _, _ in people.withLock { $0 } }
    await pose.process(frame, record: record())
    #expect(pose.latest != nil)

    people.withLock { $0 = [lying, person(center: [0.5, 0.2], axisDegrees: 180, aspect: 4.0 / 3)] }
    await pose.process(frame, record: record(id: 2, at: 10.03))
    let latest = try #require(pose.latest)
    #expect(latest.frameID == 2)
    #expect(abs(latest.target.center.y - 0.6) < 0.05, "still on the first patient")
}

// MARK: - Tapping a person to lock onto them

private let otherLying = person(center: [0.5, 0.25], axisDegrees: 180, aspect: 4.0 / 3)

@Test func tappingOneOfTwoPeopleLyingDownLocksOntoThem() async throws {
    let pose = worker([lying, otherLying])
    pose.requestLock(at: [0.5, 0.25])
    #expect(pose.lockStatus == .locking)
    await pose.process(frame, record: record())
    #expect(pose.lockStatus == .locked)
    let latest = try #require(pose.latest)
    #expect(abs(latest.target.center.y - 0.25) < 0.05, "on the one tapped")
    #expect(pose.jointPose?.skeletons.count == 1, "only their body draws")

    await pose.process(frame, record: record(id: 2, at: 10.03))
    #expect(abs((try #require(pose.latest)).target.center.y - 0.25) < 0.05, "and it stays on them")
}

@Test func tappingSomeoneUprightLocksNothing() async throws {
    let pose = worker([lying, upright])
    await pose.process(frame, record: record())
    pose.requestLock(at: [0.2, 0.4])
    await pose.process(frame, record: record(id: 2, at: 10.03))
    #expect(pose.lockStatus == .notLying)
    #expect(abs((try #require(pose.latest)).target.center.y - 0.6) < 0.05, "the patient lying down keeps the body")
}

@Test func aLockedPatientOutOfSightIsLetGoForTheOneLyingDown() async throws {
    let people = Mutex([lying, otherLying])
    let pose = PoseWorker { _, _ in people.withLock { $0 } }
    pose.requestLock(at: [0.5, 0.25])
    await pose.process(frame, record: record())
    #expect(pose.lockStatus == .locked)

    people.withLock { $0 = [lying] }
    await pose.process(frame, record: record(id: 2, at: 10.5))
    #expect(pose.lastNoTargetReason == .notNearLock, "held a moment for the one tapped")
    await pose.process(frame, record: record(id: 3, at: 10 + PoseWorker.lockLostSeconds + 0.1))
    #expect(abs((try #require(pose.latest)).target.center.y - 0.6) < 0.05)
    #expect(pose.lockStatus == .none)
}

@Test func onlyThePatientsSkeletonDraws() async {
    let pose = worker([lying, upright])
    await pose.process(frame, record: record())
    #expect(pose.jointPose?.skeletons.count == 1)
    let alone = worker([upright])
    await alone.process(frame, record: record())
    #expect(alone.jointPose?.skeletons.isEmpty == true, "nobody lying down, so no body at all")
}

@Test func aOneFrameDropoutLeavesTheTargetToAgeOut() async {
    let people = Mutex([lying])
    let pose = PoseWorker { _, _ in people.withLock { $0 } }
    await pose.process(frame, record: record(id: 1, at: 10))

    people.withLock { $0 = [] }
    await pose.process(frame, record: record(id: 2, at: 10.03))
    #expect(pose.latest?.frameID == 1)
    #expect(pose.lastNoTargetReason == .noPeople)
}

@Test func scansRotationsUntilOneFindsThePatientThenStays() async {
    // Only the sensor-native rotation sees the patient, as for a body lying across a portrait phone.
    let tried = Mutex<[CaptureRotation]>([])
    let pose = PoseWorker { _, rotation in
        tried.withLock { $0.append(rotation) }
        return rotation == .up ? [lying] : []
    }
    for id in 1...5 {
        await pose.process(frame, record: record(id: UInt64(id)))
    }
    #expect(tried.withLock { $0 } == [.right, .up, .up, .up, .up])
    #expect(pose.currentRotation == .up)
}

@Test func leavesALockedRotationOnlyAfterRepeatedMisses() {
    var scan = PoseOrientationScan()
    #expect(scan.current == .right)
    scan.record(foundTarget: true)
    scan.record(foundTarget: false)
    scan.record(foundTarget: false)
    #expect(scan.current == .right)
    scan.record(foundTarget: false)
    #expect(scan.current == .up)
    scan.record(foundTarget: false)
    #expect(scan.current == .left)
    scan.record(foundTarget: false)
    #expect(scan.current == .down)
    scan.record(foundTarget: false)
    #expect(scan.current == .right)
}

@Test func realVisionRequestRunsOnABlankFrame() async {
    let blank = CapturedFrame(id: 1, pixels: makePixels(width: 640, height: 480))
    for rotation in CaptureRotation.allCases {
        #expect(await VisionPoseDetector().detect(blank, rotation: rotation).isEmpty)
    }
}

// Vision can't be shown a person here, but any Vision request reports points the same way, so a
// white rectangle checks the mapping that keypoints go through.
@Test(arguments: CaptureRotation.allCases)
func visionPointsMapBackToTheCapturedPixels(rotation: CaptureRotation) async throws {
    let rect = CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.5)
    let pixels = makePixels(width: 640, height: 480, whiteRect: rect)
    let found = try await DetectRectanglesRequest().perform(on: pixels, orientation: rotation.cgOrientation)
    let rectangle = try #require(found.first)
    let corners = [rectangle.topLeft, rectangle.topRight, rectangle.bottomLeft, rectangle.bottomRight]
    let center = corners.reduce(SIMD2<Double>(0, 0)) { $0 + [$1.x, $1.y] } / 4
    let capture = rotation.captureNormalized(fromVision: center)
    #expect(isClose(capture, [Double(rect.midX), Double(rect.midY)], 0.02), "got \(capture)")
}
