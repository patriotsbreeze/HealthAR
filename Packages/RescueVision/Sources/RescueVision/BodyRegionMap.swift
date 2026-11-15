import Foundation
import simd

/// Which part of a limb a capsule covers. Left and right are left out: Vision's labels can swap,
/// and the tap on the injury is what says which limb.
public enum LimbSegment: String, Sendable, CaseIterable, Hashable {
    case upperArm = "upper_arm"
    case forearm
    case thigh
    case lowerLeg = "lower_leg"

    /// Full width, as a fraction of shoulder width and of the segment's own length. The larger
    /// wins, so foreshortening either one still leaves a limb-sized capsule.
    var widthFractions: (shoulders: Double, length: Double) {
        switch self {
        case .upperArm: (0.28, 0.32)
        case .forearm: (0.24, 0.30)
        case .thigh: (0.42, 0.36)
        case .lowerLeg: (0.30, 0.28)
        }
    }
}

/// One side's segment, with the joints at its ends.
struct LimbBone: Sendable, Hashable {
    var segment: LimbSegment
    var isLeft: Bool

    static let all: [LimbBone] = LimbSegment.allCases.flatMap { [LimbBone(segment: $0, isLeft: true), LimbBone(segment: $0, isLeft: false)] }

    var joints: (from: BodyJoint, to: BodyJoint) {
        switch (segment, isLeft) {
        case (.upperArm, true): (.leftShoulder, .leftElbow)
        case (.upperArm, false): (.rightShoulder, .rightElbow)
        case (.forearm, true): (.leftElbow, .leftWrist)
        case (.forearm, false): (.rightElbow, .rightWrist)
        case (.thigh, true): (.leftHip, .leftKnee)
        case (.thigh, false): (.rightHip, .rightKnee)
        case (.lowerLeg, true): (.leftKnee, .leftAnkle)
        case (.lowerLeg, false): (.rightKnee, .rightAnkle)
        }
    }
}

/// A rectangle laid along the body. Its center is in capture image space. The axis and sizes are
/// isotropic, in image heights, because normalized x and y have different scales.
struct OrientedRect: Sendable, Equatable {
    var center: SIMD2<Double>
    /// Unit, head to feet.
    var axis: SIMD2<Double>
    var halfLength: Double
    var halfWidth: Double

    /// In capture image space, going round.
    func corners(imageAspect: Double) -> [SIMD2<Double>] {
        let center = SIMD2(self.center.x * imageAspect, self.center.y)
        let along = axis * halfLength
        let across = SIMD2(-axis.y, axis.x) * halfWidth
        return [center - along - across, center - along + across, center + along + across, center + along - across]
            .map { [$0.x / imageAspect, $0.y] }
    }
}

/// A rounded segment over a limb. Ends in capture image space, radius in image heights.
struct LimbCapsule: Sendable, Equatable {
    var from: SIMD2<Double>
    var to: SIMD2<Double>
    var radius: Double
    var segment: LimbSegment
    /// Both joints well seen. Solid when locked, dashed otherwise.
    var isLocked: Bool

    var midpoint: SIMD2<Double> { (from + to) / 2 }
}

/// The whole patient, for a see-through figure under the step's own mark, so the helper can see who
/// pose found and that it lines up. In capture image space. It shows where the body is and gates nothing.
struct BodyOutline: Sendable, Equatable {
    /// Left shoulder, right shoulder, right hip, left hip: going round, whichever way the labels fall.
    var torso: [SIMD2<Double>]
    /// Hips seen, not placed from the head, and every corner well seen.
    var torsoLocked: Bool
    var head: Head?
    /// Every limb segment pose saw well enough to place, each as wide as the limb.
    var limbs: [LimbCapsule]

    struct Head: Sendable, Equatable {
        var center: SIMD2<Double>
        /// In image heights.
        var radius: Double
        var isLocked: Bool
    }
}

/// What one pose frame lights up.
struct BodyRegions: Sendable, Equatable {
    var chest: OrientedRect?
    var chestLocked = false
    /// Pad 1 sits under the patient's right collarbone, pad 2 on their left side below the armpit.
    var padOne: OrientedRect?
    var padTwo: OrientedRect?
    var padsLocked = false
    var limb: LimbCapsule?
    /// Between the shoulder blades and just above the navel of a standing patient, for choking.
    var upperBack: OrientedRect?
    var upperAbdomen: OrientedRect?
    var uprightLocked = false
    /// The patient found lying down, on the steps that look for one.
    var outline: BodyOutline?
}

/// UNVALIDATED DEMO ESTIMATE, like TorsoMap. Pad and limb geometry are our own fractions of an
/// adult torso, tuned on a manikin. A clinician must confirm them before they guide anyone. They
/// are coarse aids that gate nothing.
///
/// The patient's sides come from geometry, never from Vision's left and right labels, which can
/// swap from frame to frame on someone lying face up. With a running from shoulders to hips,
/// the patient's right is (-a.y, a.x) in y-down image axes, as long as the camera sees the front
/// of the body, which it always does for CPR and pads. Nothing between the sensor and the screen
/// mirrors the image. The labels only decide solid or dashed.
enum BodyRegionMap {
    /// Around the ring's center, a little bigger than the hands drawn on it.
    static let chestHalfLength = 1.4
    static let chestHalfWidth = 1.1
    /// Under this, in image heights, a capsule would be a line.
    static let minimumLimbWidth = 0.03
    /// An adult head is about this wide across, in shoulder widths.
    static let headRadiusFraction = 0.3

    static func lying(_ person: DetectedPerson, imageAspect: Double) -> BodyRegions? {
        guard let chest = chest(torso: person.torso, imageAspect: imageAspect) else { return nil }
        var regions = BodyRegions(chest: chest, chestLocked: !person.torsoEstimated, outline: outline(person, imageAspect: imageAspect))
        if let pads = pads(torso: person.torso, imageAspect: imageAspect) {
            regions.padOne = pads.one
            regions.padTwo = pads.two
            regions.padsLocked = pads.labelsAgree && !person.torsoEstimated
        }
        return regions
    }

    /// How far from the shoulders toward the hips each choking mark sits. UNVALIDATED DEMO ESTIMATE,
    /// like TorsoMap: our own fractions of an adult torso, for the space between the shoulder
    /// blades and a fist's width above the navel. A clinician must confirm them. Both use only the
    /// shoulder and hip midpoints, which are the same from the front or the back, so they hold
    /// whichever way the patient faces the camera.
    static let upperBackAlong = 0.25
    static let upperAbdomenAlong = 0.70

    /// A standing or seated patient, for back blows and abdominal thrusts. Nil wherever TorsoMap would
    /// give no ring, since the torso is too small or too foreshortened to place anything on.
    static func upright(_ person: DetectedPerson, imageAspect: Double, alone: Bool) -> BodyRegions? {
        let torso = person.torso
        guard TorsoMap.target(for: torso, imageAspect: imageAspect) != nil,
              let frame = Frame(torso, imageAspect: imageAspect)
        else { return nil }
        let w = frame.shoulderWidth
        let l = frame.length
        var regions = BodyRegions(outline: outline(person, imageAspect: imageAspect))
        regions.upperBack = frame.rect(right: 0, down: upperBackAlong * l, halfLength: 0.12 * l, halfWidth: 0.22 * w)
        regions.upperAbdomen = frame.rect(right: 0, down: upperAbdomenAlong * l, halfLength: 0.08 * l, halfWidth: 0.14 * w)
        // Solid only for one well-seen person: with the rescuer in frame too, the mark may be on them.
        regions.uprightLocked = alone && !person.torsoEstimated && person.lowestConfidence >= 0.5
        return regions
    }

    /// The torso as pose has it, the head if a nose, eyes or ears were seen, and the limbs `capsule(for:)`
    /// finds plausible. The same joints and thresholds as the zones, so the figure and the marks agree.
    static func outline(_ person: DetectedPerson, imageAspect: Double) -> BodyOutline? {
        guard imageAspect > 0 else { return nil }
        let torso = person.torso
        let iso: (SIMD2<Double>) -> SIMD2<Double> = { [$0.x * imageAspect, $0.y] }
        let shoulders = simd_distance(iso(torso.leftShoulder), iso(torso.rightShoulder))
        guard shoulders.isFinite, shoulders > 1e-6 else { return nil }
        let head = person.head.flatMap { joint -> BodyOutline.Head? in
            guard joint.confidence >= PatientSelector().minConfidence else { return nil }
            return BodyOutline.Head(center: joint.position, radius: headRadiusFraction * shoulders, isLocked: joint.confidence >= 0.5)
        }
        return BodyOutline(
            torso: [torso.leftShoulder, torso.rightShoulder, torso.rightHip, torso.leftHip],
            torsoLocked: !person.torsoEstimated && person.lowestConfidence >= 0.5,
            head: head,
            limbs: LimbBone.all.compactMap { capsule(for: $0, person: person, imageAspect: imageAspect) }
        )
    }

    /// Centered where the ring is and laid along the torso. Nil wherever TorsoMap gives no ring.
    static func chest(torso: TorsoKeypoints, imageAspect: Double) -> OrientedRect? {
        guard let target = TorsoMap.target(for: torso, imageAspect: imageAspect),
              let frame = Frame(torso, imageAspect: imageAspect)
        else { return nil }
        return OrientedRect(
            center: target.center,
            axis: frame.axis,
            halfLength: target.radius * chestHalfLength,
            halfWidth: target.radius * chestHalfWidth
        )
    }

    static func pads(torso: TorsoKeypoints, imageAspect: Double) -> (one: OrientedRect, two: OrientedRect, labelsAgree: Bool)? {
        guard TorsoMap.target(for: torso, imageAspect: imageAspect) != nil,
              let frame = Frame(torso, imageAspect: imageAspect)
        else { return nil }
        let w = frame.shoulderWidth
        let l = frame.length
        let one = frame.rect(right: 0.28 * w, down: 0.18 * l, halfLength: 0.13 * l, halfWidth: 0.15 * w)
        let two = frame.rect(right: -0.50 * w, down: 0.62 * l, halfLength: 0.15 * l, halfWidth: 0.11 * w)
        return (one, two, frame.labelsAgree)
    }

    /// The segment nearest the pin, if one is close enough. The last one chosen stays unless
    /// another is more than 20% closer and by more than half its radius, so a pin near the elbow
    /// doesn't flicker between two.
    static func limb(person: DetectedPerson, anchor: SIMD2<Double>, imageAspect: Double, previous: LimbBone?) -> (bone: LimbBone, capsule: LimbCapsule)? {
        guard imageAspect > 0 else { return nil }
        let point = SIMD2(anchor.x * imageAspect, anchor.y)
        let near: [(bone: LimbBone, capsule: LimbCapsule, distance: Double)] = LimbBone.all.compactMap { bone in
            guard let capsule = capsule(for: bone, person: person, imageAspect: imageAspect) else { return nil }
            let distance = distance(from: point, to: capsule, imageAspect: imageAspect)
            guard distance <= max(2.5 * capsule.radius, 0.05) else { return nil }
            return (bone, capsule, distance)
        }
        guard let best = near.min(by: { $0.distance < $1.distance }) else { return nil }
        if let kept = near.first(where: { $0.bone == previous }),
           best.distance >= 0.8 * kept.distance || kept.distance - best.distance <= 0.5 * kept.capsule.radius {
            return (kept.bone, kept.capsule)
        }
        return (best.bone, best.capsule)
    }

    /// A segment that locked earlier, after the pin is gone. It has to stay near where it was,
    /// or pose has moved on to someone else's limb. Followed by where it is, not by Vision's left or
    /// right, which can swap on someone lying down: either side's segment will do, and the nearer
    /// one wins, with the label it has now.
    static func held(_ bone: LimbBone, person: DetectedPerson, near anchor: SIMD2<Double>, imageAspect: Double) -> (bone: LimbBone, capsule: LimbCapsule)? {
        guard imageAspect > 0 else { return nil }
        let sides = [bone, LimbBone(segment: bone.segment, isLeft: !bone.isLeft)]
        let near = sides.compactMap { side -> (bone: LimbBone, capsule: LimbCapsule, distance: Double)? in
            guard let capsule = capsule(for: side, person: person, imageAspect: imageAspect) else { return nil }
            let distance = distance(from: [anchor.x * imageAspect, anchor.y], to: capsule, imageAspect: imageAspect)
            return distance <= max(4 * capsule.radius, 0.1) ? (side, capsule, distance) : nil
        }
        return near.min { $0.distance < $1.distance }.map { ($0.bone, $0.capsule) }
    }

    /// The same segment as a held one, wherever its label says it is: near enough to where it was.
    static func isSameLimb(_ capsule: LimbCapsule, as segment: LimbSegment, near anchor: SIMD2<Double>, imageAspect: Double) -> Bool {
        guard imageAspect > 0, capsule.segment == segment else { return false }
        return distance(from: [anchor.x * imageAspect, anchor.y], to: capsule, imageAspect: imageAspect) <= max(4 * capsule.radius, 0.1)
    }

    static func capsule(for bone: LimbBone, person: DetectedPerson, imageAspect: Double) -> LimbCapsule? {
        let names = bone.joints
        guard imageAspect > 0,
              let start = person.joint(names.from), let end = person.joint(names.to),
              min(start.confidence, end.confidence) >= 0.3
        else { return nil }
        let iso: (SIMD2<Double>) -> SIMD2<Double> = { [$0.x * imageAspect, $0.y] }
        let a = iso(start.position)
        var b = iso(end.position)
        let length = simd_distance(a, b)
        let shoulders = simd_distance(iso(person.leftShoulder.position), iso(person.rightShoulder.position))
        // A wrist at the shoulder, or a shin longer than two torsos, is Vision guessing.
        let plausible = shoulders > 0.02 ? (0.15 * shoulders...2 * shoulders).contains(length) : length >= 0.03
        guard plausible else { return nil }
        // The hand is part of what gets supported, so the forearm runs on past the wrist.
        if bone.segment == .forearm { b += (b - a) * 0.2 }
        let fractions = bone.segment.widthFractions
        let width = max(fractions.shoulders * shoulders, fractions.length * length, minimumLimbWidth)
        return LimbCapsule(
            from: [a.x / imageAspect, a.y],
            to: [b.x / imageAspect, b.y],
            radius: width / 2,
            segment: bone.segment,
            isLocked: min(start.confidence, end.confidence) >= 0.5
        )
    }

    private static func distance(from point: SIMD2<Double>, to capsule: LimbCapsule, imageAspect: Double) -> Double {
        PatientSelector.distance(
            from: point,
            toSegment: [capsule.from.x * imageAspect, capsule.from.y],
            [capsule.to.x * imageAspect, capsule.to.y]
        )
    }

    /// The torso's own axes, in isotropic image heights.
    private struct Frame {
        var shoulderMid: SIMD2<Double>
        /// Unit, shoulders to hips.
        var axis: SIMD2<Double>
        /// Unit, toward the patient's right.
        var right: SIMD2<Double>
        var shoulderWidth: Double
        var length: Double
        var labelsAgree: Bool
        var imageAspect: Double

        init?(_ torso: TorsoKeypoints, imageAspect: Double) {
            guard imageAspect > 0 else { return nil }
            let iso: (SIMD2<Double>) -> SIMD2<Double> = { [$0.x * imageAspect, $0.y] }
            // Both midpoints are the same whichever way the labels fall.
            shoulderMid = iso(TorsoMap.bilinear(torso, u: 0.5, v: 0))
            let toHips = iso(TorsoMap.bilinear(torso, u: 0.5, v: 1)) - shoulderMid
            length = simd_length(toHips)
            guard length > 1e-6 else { return nil }
            axis = toHips / length
            right = [-axis.y, axis.x]
            let labelled = iso(torso.rightShoulder) - iso(torso.leftShoulder)
            shoulderWidth = simd_length(labelled)
            labelsAgree = simd_dot(labelled, right) > 0
            self.imageAspect = imageAspect
        }

        func rect(right offset: Double, down: Double, halfLength: Double, halfWidth: Double) -> OrientedRect {
            let center = shoulderMid + right * offset + axis * down
            return OrientedRect(
                center: [center.x / imageAspect, center.y],
                axis: axis,
                halfLength: max(halfLength, 0.015),
                halfWidth: max(halfWidth, 0.015)
            )
        }
    }
}
