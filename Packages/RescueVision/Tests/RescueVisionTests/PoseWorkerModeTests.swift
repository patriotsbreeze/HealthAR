import Foundation
import Synchronization
import Testing
@testable import RescueVision

private let lying = person(center: [0.5, 0.6], axisDegrees: 0, aspect: 4.0 / 3)
private let frame = CapturedFrame(id: 1, pixels: makePixels())

private func record(id: UInt64 = 1, at time: Double = 10) -> FrameRecord {
    FrameRecord(id: id, timestamp: time, pose: cameraPose(), tracking: .normal)
}

/// Holds each detection until released, the way a slow Vision request does.
private final class GatedDetector: Sendable {
    private let waiters = Mutex<[CheckedContinuation<Void, Never>]>([])
    let people: [DetectedPerson]

    init(_ people: [DetectedPerson]) { self.people = people }

    var waiting: Int { waiters.withLock { $0.count } }

    func detect() async -> [DetectedPerson] {
        await withCheckedContinuation { continuation in waiters.withLock { $0.append(continuation) } }
        return people
    }

    func release() {
        let held = waiters.withLock { waiters -> [CheckedContinuation<Void, Never>] in
            let held = waiters
            waiters = []
            return held
        }
        for waiter in held { waiter.resume() }
    }
}

/// The step changed while Vision was still working on the last step's frame.
@Test func aFrameStillInDetectionWhenTheStepChangesLandsNowhere() async {
    let gated = GatedDetector([lying])
    let worker = PoseWorker { _, _ in await gated.detect() }
    let late = Task { await worker.process(frame, record: record()) }
    #expect(await waitUntil { gated.waiting == 1 })
    worker.reset()
    gated.release()
    await late.value
    #expect(worker.latest == nil)
    #expect(worker.latestPose == nil)
}

@Test func theLyingWorkerPublishesTheRingAndTheZonesFromOneFrame() async throws {
    let worker = PoseWorker { _, _ in [lying] }
    await worker.process(frame, record: record(id: 4))
    let snapshot = worker.snapshot
    let latest = try #require(snapshot.latest)
    let pose = try #require(snapshot.pose)
    #expect(latest.frameID == pose.frameID)
    #expect(pose.regions.chest?.center == latest.target.center)
    #expect(pose.regions.padOne != nil && pose.regions.padTwo != nil)
    #expect(pose.regions.limb == nil)
}

@Test func nearAPinWithNoAnchorAndNothingHeldFindsNothing() async {
    let worker = PoseWorker { _, _ in [fullPerson(axisDegrees: 0)] }
    await worker.process(frame, record: record(), request: .nearPin(anchor: nil))
    #expect(worker.latestPose == nil)
    #expect(worker.lastNoTargetReason == .notNearPin)
    #expect(!worker.holdsLimb)
}

/// Near a pin the person can sit up, and only the limb is published. The ring is the lying patient's alone.
@Test func nearAPinOnlyTheLimbIsPublished() async throws {
    let seated = fullPerson(center: [0.5, 0.5], axisDegrees: 90)
    let worker = PoseWorker { _, _ in [seated] }
    let wrist = seated.joint(.rightWrist)!.position
    let elbow = seated.joint(.rightElbow)!.position
    await worker.process(frame, record: record(), request: .nearPin(anchor: (wrist + elbow) / 2))
    let regions = try #require(worker.latestPose?.regions)
    #expect(regions.limb?.segment == .forearm)
    #expect(regions.chest == nil && regions.padOne == nil)
    #expect(worker.latest == nil)
    #expect(worker.holdsLimb)
}

@Test func smoothingSteadiesAJitteringRing() async throws {
    let people = Mutex(lying)
    let worker = PoseWorker { _, _ in [people.withLock { $0 }] }
    var raw: [Double] = []
    var shown: [Double] = []
    for tick in 0..<60 {
        let jitter = tick.isMultiple(of: 2) ? 0.004 : -0.004
        let shaken = lying.mapPositions { _, position in position + [0, jitter] }
        people.withLock { $0 = shaken }
        await worker.process(frame, record: record(id: UInt64(tick + 1), at: 10 + Double(tick) / 30))
        raw.append(try #require(TorsoMap.target(for: shaken.torso, imageAspect: 4.0 / 3)).center.y)
        shown.append(try #require(worker.latest).target.center.y)
    }
    let spread: ([Double]) -> Double = { values in (values.max() ?? 0) - (values.min() ?? 0) }
    #expect(spread(Array(shown.dropFirst(10))) < spread(Array(raw.dropFirst(10))) / 2)
}

/// After the pin's time only the held limb keeps the capsule up. Vision swapping left and right on
/// someone lying down mustn't move it to the other arm, or drop it.
@Test func aHeldLimbRidesOutALabelSwapAfterThePin() async throws {
    let lying = fullPerson(center: [0.5, 0.5], axisDegrees: 0)
    var swapped = lying
    for (left, right) in [(BodyJoint.leftElbow, BodyJoint.rightElbow), (.leftWrist, .rightWrist)] {
        swapped.extras[left] = lying.extras[right]
        swapped.extras[right] = lying.extras[left]
    }
    let people = Mutex([lying])
    let worker = PoseWorker { _, _ in people.withLock { $0 } }
    let pin = (lying.joint(.leftElbow)!.position + lying.joint(.leftWrist)!.position) / 2
    await worker.process(frame, record: record(id: 1, at: 10), request: .nearPin(anchor: pin))
    let tapped = try #require(worker.latestPose?.regions.limb)
    #expect(worker.holdsLimb)

    people.withLock { $0 = [swapped] }
    for tick in 1...30 {
        await worker.process(frame, record: record(id: UInt64(tick + 1), at: 10 + Double(tick) / 10), request: .nearPin(anchor: nil))
    }
    #expect(worker.holdsLimb, "the tap chose the limb, not its label")
    let limb = try #require(worker.latestPose?.regions.limb)
    #expect(worker.latestPose?.capturedAt == 13)
    #expect(limb.segment == .forearm)
    #expect(isClose(limb.midpoint, tapped.midpoint, 0.01), "still on the arm that was tapped")
}
