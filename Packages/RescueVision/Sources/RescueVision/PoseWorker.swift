import CoreVideo
import Foundation
import Synchronization
import Vision

typealias PoseDetector = @Sendable (CapturedFrame, CaptureRotation) async -> [DetectedPerson]

/// A person lying across a portrait phone looks sideways to Vision, and Apple warns accuracy
/// drops for people upside down. So try each rotation until one finds a target, then stay on it.
struct PoseOrientationScan: Sendable {
    static let order: [CaptureRotation] = [.right, .up, .left, .down]
    /// Ride out a few misses on a rotation that was working.
    static let missesBeforeLeaving = 3

    private var index = 0
    private var misses = 0
    private var locked = false

    var current: CaptureRotation { Self.order[index] }

    mutating func record(foundTarget: Bool) {
        if foundTarget {
            misses = 0
            locked = true
            return
        }
        misses += 1
        if !locked || misses >= Self.missesBeforeLeaving {
            index = (index + 1) % Self.order.count
            misses = 0
            locked = false
        }
    }
}

struct PoseDetection: Sendable {
    var people: [DetectedPerson]
    var joints: [SIMD2<Double>]
    var skeletons: [DetectedSkeleton] = []
}

typealias PoseFrameDetector = @Sendable (CapturedFrame, CaptureRotation) async -> PoseDetection

struct VisionPoseDetector: Sendable {
    private let request: DetectHumanBodyPoseRequest = {
        var request = DetectHumanBodyPoseRequest()
        request.detectsHands = false
        return request
    }()

    func detect(_ frame: CapturedFrame, rotation: CaptureRotation) async -> [DetectedPerson] {
        await detectFrame(frame, rotation: rotation).people
    }

    func detectFrame(_ frame: CapturedFrame, rotation: CaptureRotation) async -> PoseDetection {
        // A failed request is the same as seeing nobody: no ring, and voice carries on.
        guard let observations = try? await request.perform(on: frame.pixels, orientation: rotation.cgOrientation) else {
            return PoseDetection(people: [], joints: [])
        }
        // Capture image space is the buffer as captured, so its aspect is the buffer's.
        let aspect = Double(CVPixelBufferGetWidth(frame.pixels)) / Double(max(1, CVPixelBufferGetHeight(frame.pixels)))
        var skeletons: [DetectedSkeleton] = []
        let people = observations.compactMap { observation -> DetectedPerson? in
            var joints: [BodyJoint: DetectedPerson.Joint] = [:]
            for (name, joint) in observation.allJoints() {
                guard let body = BodyJoint(name) else { continue }
                joints[body] = DetectedPerson.Joint(
                    position: rotation.captureNormalized(fromVision: [joint.location.x, joint.location.y]),
                    confidence: Double(joint.confidence)
                )
            }
            let skeleton = DetectedSkeleton(joints: joints)
            if !skeleton.joints.isEmpty { skeletons.append(skeleton) }
            return DetectedPerson(joints: joints, imageAspect: aspect)
        }
        return PoseDetection(
            people: people,
            joints: skeletons.flatMap { skeleton in BodyJoint.cprJoints.compactMap { skeleton.joints[$0] } },
            skeletons: skeletons
        )
    }
}

extension BodyJoint {
    init?(_ name: HumanBodyPoseObservation.JointName) {
        switch name {
        case .leftEar: self = .leftEar
        case .leftEye: self = .leftEye
        case .rightEar: self = .rightEar
        case .rightEye: self = .rightEye
        case .neck: self = .neck
        case .nose: self = .nose
        case .leftShoulder: self = .leftShoulder
        case .leftElbow: self = .leftElbow
        case .leftWrist: self = .leftWrist
        case .rightShoulder: self = .rightShoulder
        case .rightElbow: self = .rightElbow
        case .rightWrist: self = .rightWrist
        case .root: self = .root
        case .leftHip: self = .leftHip
        case .leftKnee: self = .leftKnee
        case .leftAnkle: self = .leftAnkle
        case .rightHip: self = .rightHip
        case .rightKnee: self = .rightKnee
        case .rightAnkle: self = .rightAnkle
        // A joint a later SDK adds is one nothing here draws.
        @unknown default: return nil
        }
    }
}

/// What pose is asked to find in a frame.
enum PoseRequest: Sendable, Equatable {
    /// Display joints without selecting a patient or changing guidance.
    case joints
    case lying
    /// `anchor` is the pin in this frame's capture image, or nil once it is gone or out of sight.
    case nearPin(anchor: SIMD2<Double>?)
    /// Goes through `rescuer(_:record:)`, never `process`.
    case rescuer
}

/// Body regions from one camera frame.
struct TimedPose: Sendable, Equatable {
    var regions: BodyRegions
    /// Measured joints in capture image coordinates; skeletons preserve each person and joint name.
    var joints: [SIMD2<Double>] = []
    var skeletons: [DetectedSkeleton] = []
    var frameID: UInt64
    var capturedAt: TimeInterval

    func age(at now: TimeInterval) -> TimeInterval { now - capturedAt }
}

/// Turns one frame into a published chest target and body regions. `VisionSession` feeds it from
/// a one-slot mailbox, so it always works on the newest frame, and reading the result never waits on it.
final class PoseWorker: Sendable {
    /// A segment that locked near the pin. It stays while pose tracks it, after the pin's time is up,
    /// since the tap already chose it.
    private struct HeldLimb {
        var bone: LimbBone
        var anchor: SIMD2<Double>
        var seenAt: TimeInterval
    }

    private struct State {
        var scan = PoseOrientationScan()
        var latest: TimedTorsoTarget?
        var latestPose: TimedPose?
        var jointPose: TimedPose?
        var patientBody: TimedPatientBody?
        var chestEstimate: TimedChestEstimate?
        var lastNoTargetReason: NoTargetReason?
        var smoother = JointSmoother()
        var lastBone: LimbBone?
        var held: HeldLimb?
        /// Bumped by `reset()`, so a frame still in detection when the step changed lands nowhere.
        var generation: UInt64 = 0
    }

    /// A held limb rides out this long untracked, for a dropped frame or two.
    static let heldLimbGrace: TimeInterval = 0.5

    private let state = Mutex(State())
    private let detect: PoseFrameDetector
    private let selector = PatientSelector()

    init(detect: @escaping PoseDetector, detectFrame: PoseFrameDetector? = nil) {
        self.detect = detectFrame ?? { frame, rotation in
            let people = await detect(frame, rotation)
            return PoseDetection(people: people, joints: people.flatMap(\.visibleJoints), skeletons: people.map { DetectedSkeleton(person: $0) })
        }
    }

    var jointPose: TimedPose? { state.withLock { $0.jointPose } }

    var chestEstimate: TimedChestEstimate? { state.withLock { $0.chestEstimate } }

    var patientBody: TimedPatientBody? { state.withLock { $0.patientBody } }

    var latest: TimedTorsoTarget? { state.withLock { $0.latest } }
    var latestPose: TimedPose? { state.withLock { $0.latestPose } }
    /// Both from one lock, so the ring and the chest zone always come from the same frame.
    var snapshot: (latest: TimedTorsoTarget?, pose: TimedPose?) { state.withLock { ($0.latest, $0.latestPose) } }
    var lastNoTargetReason: NoTargetReason? { state.withLock { $0.lastNoTargetReason } }
    var currentRotation: CaptureRotation { state.withLock { $0.scan.current } }
    var holdsLimb: Bool { state.withLock { $0.held != nil } }

    /// For a new step. The rotation scan is kept, since the phone is still held the same way.
    func reset() {
        state.withLock { state in
            state.generation += 1
            state.latest = nil
            state.latestPose = nil
            state.jointPose = nil
            state.patientBody = nil
            state.chestEstimate = nil
            state.lastNoTargetReason = nil
            state.smoother.reset()
            state.lastBone = nil
            state.held = nil
        }
    }

    /// The person compressing, upright in the portrait-locked app, so no rotation scan.
    @concurrent func rescuer(_ frame: CapturedFrame, record: FrameRecord) async -> CompressionSample? {
        let generation = state.withLock { $0.generation }
        let detection = await detect(frame, .right)
        publishJoints(detection, record: record, generation: generation, depth: frame.bodyDepth)
        let people = detection.people
        let gravity = record.tracking == .notAvailable ? nil : record.pose.gravityInImage
        return CompressionSignal.sample(people: people, gravity: gravity, imageAspect: record.pose.imageAspect)
    }

    @concurrent func process(_ frame: CapturedFrame, record: FrameRecord, request: PoseRequest = .lying) async {
        let (rotation, generation) = state.withLock { ($0.scan.current, $0.generation) }
        let detection = await detect(frame, rotation)
        publishJoints(detection, record: record, generation: generation, depth: frame.bodyDepth)
        let people = detection.people
        state.withLock { state in
            guard state.generation == generation else { return }
            switch request {
            case .joints:
                state.scan.record(foundTarget: !detection.joints.isEmpty || detection.skeletons.contains { !$0.joints.isEmpty })
            case .lying:
                findLying(people, record: record, in: &state)
            case let .nearPin(anchor):
                findNearPin(people, pin: anchor, record: record, in: &state)
            case .rescuer:
                break
            }
        }
    }

    private func publishJoints(_ detection: PoseDetection, record: FrameRecord, generation: UInt64, depth: BodyDepth?) {
        var fitted: PatientBodyPlacement?
        let sel = selector.select(people: detection.people, gravity: record.pose.gravityInImage, imageAspect: record.pose.imageAspect)
        let chest: TimedChestEstimate?
        if case let .patient(person) = sel {
            chest = TimedChestEstimate.estimate(person: person, depth: depth, record: record)
        } else {
            chest = nil
        }
        if record.tracking == .normal, let depth, case let .patient(person) = sel {
            fitted = PatientModelFit.fit(person: person, depth: depth, camera: record.pose)
        } else if record.tracking == .normal, let depth,
                  let person = detection.people.max(by: { $0.shoulderSpan < $1.shoulderSpan }) {
            // No lying patient: the nearest person, by shoulder span on screen, gets the outline in any pose.
            fitted = PatientModelFit.fit(person: person, depth: depth, camera: record.pose, requireLying: false)
        }
        state.withLock { state in
            guard state.generation == generation else { return }
            state.jointPose = TimedPose(regions: BodyRegions(), joints: detection.joints, skeletons: detection.skeletons, frameID: record.id, capturedAt: record.timestamp)
            // Never hold a chest marker on an ambiguous or lost patient.
            state.chestEstimate = chest
            // One frame failing the depth fit keeps the last good one, which still ages out on its own.
            if let fitted { state.patientBody = TimedPatientBody(placement: fitted, capturedAt: record.timestamp) }
        }
    }

    private func findLying(_ people: [DetectedPerson], record: FrameRecord, in state: inout State) {
        let pose = record.pose
        let gravity = record.tracking == .notAvailable ? nil : pose.gravityInImage
        var reason: NoTargetReason?
        var found = false
        switch selector.select(people: people, gravity: gravity, imageAspect: pose.imageAspect) {
        case let .patient(person):
            let smoothed = state.smoother.smooth(person, at: record.timestamp, imageAspect: pose.imageAspect)
            if let target = TorsoMap.target(for: smoothed.torso, imageAspect: pose.imageAspect),
               let regions = BodyRegionMap.lying(smoothed, imageAspect: pose.imageAspect) {
                found = true
                state.latest = TimedTorsoTarget(
                    target: target,
                    frameID: record.id,
                    capturedAt: record.timestamp,
                    shoulders: (smoothed.leftShoulder.position + smoothed.rightShoulder.position) / 2,
                    hips: (smoothed.leftHip.position + smoothed.rightHip.position) / 2
                )
                state.latestPose = TimedPose(regions: regions, joints: smoothed.visibleJoints, frameID: record.id, capturedAt: record.timestamp)
            } else {
                reason = .torsoUnusable
            }
        case let .none(why):
            reason = why
        }
        state.scan.record(foundTarget: found)
        state.lastNoTargetReason = reason
        if reason == .multipleCandidates {
            // The ring could be on the wrong person, so don't let it linger until stale.
            // Other misses just age out, which rides out a one-frame detection dropout.
            state.latest = nil
            state.latestPose = nil
        }
    }

    private func findNearPin(_ people: [DetectedPerson], pin: SIMD2<Double>?, record: FrameRecord, in state: inout State) {
        let aspect = record.pose.imageAspect
        let now = record.timestamp
        if let held = state.held, pin == nil, now - held.seenAt > Self.heldLimbGrace {
            state.held = nil
        }
        guard let anchor = pin ?? state.held?.anchor else {
            state.lastNoTargetReason = .notNearPin
            return
        }

        var joints: [SIMD2<Double>] = []
        var choice: (bone: LimbBone, capsule: LimbCapsule)?
        switch selector.selectNearest(people: people, anchor: anchor, imageAspect: aspect) {
        case let .patient(person):
            state.scan.record(foundTarget: true)
            let smoothed = state.smoother.smooth(person, at: now, imageAspect: aspect)
            joints = smoothed.visibleJoints
            if pin != nil {
                choice = BodyRegionMap.limb(person: smoothed, anchor: anchor, imageAspect: aspect, previous: state.lastBone)
            } else if let held = state.held {
                // Its label may have swapped since, so the bone that comes back is the one to keep.
                choice = BodyRegionMap.held(held.bone, person: smoothed, near: held.anchor, imageAspect: aspect)
            }
            state.lastNoTargetReason = choice == nil ? .notNearPin : nil
        case let .none(why):
            state.scan.record(foundTarget: false)
            state.lastNoTargetReason = why
        }

        guard let choice else { return }
        state.lastBone = choice.bone
        // The held limb by where it is, not by its label, which can swap while the pin is still up.
        let stillHeld = state.held.map {
            BodyRegionMap.isSameLimb(choice.capsule, as: $0.bone.segment, near: $0.anchor, imageAspect: aspect)
        } ?? false
        if choice.capsule.isLocked || stillHeld {
            state.held = HeldLimb(bone: choice.bone, anchor: choice.capsule.midpoint, seenAt: now)
        } else {
            // The pin moved to a limb that hasn't locked yet, so the old one isn't what was tapped.
            state.held = nil
        }
        state.latestPose = TimedPose(regions: BodyRegions(limb: choice.capsule), joints: joints, frameID: record.id, capturedAt: now)
    }
}

private extension DetectedPerson {
    var shoulderSpan: Double { simd_distance(leftShoulder.position, rightShoulder.position) }
}
