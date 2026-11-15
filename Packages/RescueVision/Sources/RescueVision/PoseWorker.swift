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
        /// When a lying patient was last picked out, in either pose mode. The ghost shows only while one is.
        var patientSeenAt: TimeInterval?
        /// The frame whose pick for the patient lying down was upright by depth: sitting, standing or kneeling.
        var uprightFrameID: UInt64?
        /// The patient's torso centre, in capture image space, followed frame to frame, so only they get
        /// the body however many others lie in view. Set by a tap, or by the first one found lying down.
        var lock: SIMD2<Double>?
        var lockSeenAt: TimeInterval?
        /// A tap waiting for the next frame to say who it landed on.
        var pendingLock: SIMD2<Double>?
        var lockStatus = PatientLockStatus.none
        /// Bumped whenever the lock moves to someone new, so the ghost can kneel by them instead.
        var lockGeneration: UInt64 = 0
        /// Hands are looked for only while the hand placement guide is up, since it costs a second request.
        var wantsHands = false
        var hands: TimedHands?
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
    private let detectHands: HandFrameDetector
    private let selector = PatientSelector()

    init(detect: @escaping PoseDetector, detectFrame: PoseFrameDetector? = nil, detectHands: HandFrameDetector? = nil) {
        self.detectHands = detectHands ?? { frame, rotation in await VisionHandDetector().detect(frame, rotation: rotation) }
        self.detect = detectFrame ?? { frame, rotation in
            let people = await detect(frame, rotation)
            return PoseDetection(people: people, joints: people.flatMap(\.visibleJoints), skeletons: people.map { DetectedSkeleton(person: $0) })
        }
    }

    var jointPose: TimedPose? { state.withLock { $0.jointPose } }

    var chestEstimate: TimedChestEstimate? { state.withLock { $0.chestEstimate } }

    var hands: TimedHands? { state.withLock { $0.hands } }

    func setWantsHands(_ wants: Bool) {
        state.withLock { state in
            state.wantsHands = wants
            if !wants { state.hands = nil }
        }
    }

    var patientBody: TimedPatientBody? { state.withLock { $0.patientBody } }
    var patientSeenAt: TimeInterval? { state.withLock { $0.patientSeenAt } }

    var latest: TimedTorsoTarget? { state.withLock { $0.latest } }
    var latestPose: TimedPose? { state.withLock { $0.latestPose } }
    /// Both from one lock, so the ring and the chest zone always come from the same frame.
    var snapshot: (latest: TimedTorsoTarget?, pose: TimedPose?) { state.withLock { ($0.latest, $0.latestPose) } }
    var lastNoTargetReason: NoTargetReason? { state.withLock { $0.lastNoTargetReason } }
    var currentRotation: CaptureRotation { state.withLock { $0.scan.current } }
    var lockStatus: PatientLockStatus { state.withLock { $0.lockStatus } }
    var lockGeneration: UInt64 { state.withLock { $0.lockGeneration } }

    /// A locked patient out of sight this long is let go, and the one person lying down is the patient again.
    static let lockLostSeconds: TimeInterval = 2

    /// The next frame finds who's lying down nearest this point, and locks onto them if anyone is.
    func requestLock(at image: SIMD2<Double>) {
        state.withLock { state in
            state.pendingLock = image
            state.lockStatus = .locking
        }
    }

    /// For a new rescue: the next person found lying down is the patient.
    func clearLock() {
        state.withLock { state in
            state.lock = nil
            state.lockSeenAt = nil
            state.pendingLock = nil
            state.lockStatus = .none
            state.lockGeneration += 1
        }
    }
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
            state.patientSeenAt = nil
            state.uprightFrameID = nil
            state.hands = nil
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
        _ = publishJoints(detection, record: record, generation: generation, depth: frame.bodyDepth)
        await findHands(frame, rotation: .right, record: record, generation: generation)
        let people = detection.people
        let gravity = record.tracking == .notAvailable ? nil : record.pose.gravityInImage
        return CompressionSignal.sample(people: people, gravity: gravity, imageAspect: record.pose.imageAspect)
    }

    @concurrent func process(_ frame: CapturedFrame, record: FrameRecord, request: PoseRequest = .lying) async {
        let (rotation, generation) = state.withLock { ($0.scan.current, $0.generation) }
        let detection = await detect(frame, rotation)
        let sel = publishJoints(detection, record: record, generation: generation, depth: frame.bodyDepth)
        await findHands(frame, rotation: rotation, record: record, generation: generation)
        let people = detection.people
        state.withLock { state in
            guard state.generation == generation else { return }
            switch request {
            case .joints:
                state.scan.record(foundTarget: !detection.joints.isEmpty || detection.skeletons.contains { !$0.joints.isEmpty })
            case .lying:
                findLying(sel, record: record, in: &state)
            case let .nearPin(anchor):
                findNearPin(people, pin: anchor, record: record, in: &state)
            case .rescuer:
                break
            }
        }
    }

    private func findHands(_ frame: CapturedFrame, rotation: CaptureRotation, record: FrameRecord, generation: UInt64) async {
        guard state.withLock({ $0.wantsHands }) else { return }
        let hands = await detectHands(frame, rotation)
        state.withLock { state in
            guard state.generation == generation, state.wantsHands else { return }
            state.hands = TimedHands(hands: hands, capturedAt: record.timestamp)
        }
    }

    /// The patient for this frame, picked once so the body, the ring and the ghost all follow the same
    /// person: the one locked onto if there is one, else the one person lying down.
    private func pick(_ people: [DetectedPerson], record: FrameRecord) -> (selection: PatientSelection, lock: SIMD2<Double>?, pending: Bool) {
        let gravity = record.tracking == .notAvailable ? nil : record.pose.gravityInImage
        let aspect = record.pose.imageAspect
        let (pending, lock, seenAt) = state.withLock { ($0.pendingLock, $0.lock, $0.lockSeenAt) }
        if let pending {
            let tapped = selector.select(people: people, gravity: gravity, imageAspect: aspect, lock: pending)
            if case .patient = tapped { return (tapped, pending, true) }
            // Nobody lying down where the tap landed: the patient there already keeps the body.
            let kept = lock.map { selector.select(people: people, gravity: gravity, imageAspect: aspect, lock: $0) }
            if let kept, case .patient = kept { return (kept, nil, true) }
            return (selector.select(people: people, gravity: gravity, imageAspect: aspect), nil, true)
        }
        if let lock {
            let locked = selector.select(people: people, gravity: gravity, imageAspect: aspect, lock: lock)
            let lost = seenAt.map { record.timestamp - $0 > Self.lockLostSeconds } ?? true
            if case .patient = locked { return (locked, lock, false) }
            if !lost { return (locked, lock, false) }
        }
        return (selector.select(people: people, gravity: gravity, imageAspect: aspect), nil, false)
    }

    private static func torsoCentre(_ person: DetectedPerson) -> SIMD2<Double> {
        let torso = person.torso
        return (torso.leftShoulder + torso.rightShoulder + torso.leftHip + torso.rightHip) / 4
    }

    @discardableResult
    private func publishJoints(_ detection: PoseDetection, record: FrameRecord, generation: UInt64, depth: BodyDepth?) -> PatientSelection {
        var fitted: PatientBodyPlacement?
        let picked = pick(detection.people, record: record)
        let sel = picked.selection
        // Only someone lying down gets the 3D body. Anyone sitting or standing gets none.
        // The image alone can take someone seated for someone lying down, looking down at them. Depth
        // can't: a torso it finds upright is never the patient, whatever its angle on screen.
        var upright = false
        if record.tracking == .normal, let depth, case let .patient(person) = sel {
            fitted = PatientModelFit.fit(person: person, depth: depth, camera: record.pose)
            if fitted == nil, let any = PatientModelFit.fit(person: person, depth: depth, camera: record.pose, requireLying: false) {
                upright = !any.lying
            }
        }
        var chest: TimedChestEstimate?
        if case let .patient(person) = sel, !upright {
            chest = TimedChestEstimate.estimate(person: person, depth: depth, record: record)
        }
        var patient: DetectedPerson?
        if case let .patient(person) = sel, !upright { patient = person }
        state.withLock { state in
            guard state.generation == generation else { return }
            state.uprightFrameID = upright ? record.id : nil
            if picked.pending {
                // A tap lands on someone lying down or on nothing; it never moves the lock elsewhere.
                state.pendingLock = nil
                if let patient, picked.lock != nil {
                    state.lock = Self.torsoCentre(patient)
                    state.lockSeenAt = record.timestamp
                    state.lockStatus = .locked
                    state.lockGeneration += 1
                } else {
                    state.lockStatus = .notLying
                    if let patient {
                        state.lock = Self.torsoCentre(patient)
                        state.lockSeenAt = record.timestamp
                    }
                }
            } else if let patient {
                // Follow the patient as they and the phone move. The first one found is locked onto too,
                // so someone else lying down later doesn't take the body from them.
                if picked.lock == nil, state.lock != nil { state.lockGeneration += 1 }
                if picked.lock == nil, state.lockStatus == .locked { state.lockStatus = .none }
                state.lock = Self.torsoCentre(patient)
                state.lockSeenAt = record.timestamp
            }
            if let patient { state.patientSeenAt = record.timestamp }
            // Only the patient's skeleton draws: one person, lying down, and nobody else in view.
            let skeletons = patient.map { [DetectedSkeleton(person: $0)] } ?? []
            state.jointPose = TimedPose(regions: BodyRegions(), joints: patient?.visibleJoints ?? [], skeletons: skeletons, frameID: record.id, capturedAt: record.timestamp)
            // Never hold a chest marker on an ambiguous patient. One lost for a moment, as hands
            // cover the chest, keeps the last estimate, which still ages out where it's read.
            if chest != nil || upright || sel == .none(.multipleCandidates) { state.chestEstimate = chest }
            // One frame failing the depth fit keeps the last good one, which still ages out on its own.
            if let fitted { state.patientBody = TimedPatientBody(placement: fitted, capturedAt: record.timestamp) }
        }
        return sel
    }

    private func findLying(_ selection: PatientSelection, record: FrameRecord, in state: inout State) {
        let pose = record.pose
        var reason: NoTargetReason?
        var found = false
        switch selection {
        case .patient where state.uprightFrameID == record.id:
            reason = .noHorizontalTorso
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
        if reason == .multipleCandidates || reason == .notNearLock || state.uprightFrameID == record.id {
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
