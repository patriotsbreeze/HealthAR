import Foundation
import simd

/// The 19 joints Vision's body pose reports, under our own names so nothing past the detector
/// depends on Vision's raw values, which Apple doesn't document.
enum BodyJoint: String, CaseIterable, Sendable, Hashable {
    case leftEar, leftEye, rightEar, rightEye, neck, nose
    case leftShoulder, leftElbow, leftWrist
    case rightShoulder, rightElbow, rightWrist
    case root
    case leftHip, leftKnee, leftAnkle
    case rightHip, rightKnee, rightAnkle
}

struct DetectedPerson: Sendable, Equatable {
    struct Joint: Sendable, Equatable {
        var position: SIMD2<Double>
        var confidence: Double
    }

    /// Below this Vision is guessing, so the joint counts as not seen.
    static let seenConfidence = 0.1

    var leftShoulder: Joint
    var rightShoulder: Joint
    var leftHip: Joint
    var rightHip: Joint
    /// Every other joint Vision saw. Never holds the four torso joints above.
    var extras: [BodyJoint: Joint] = [:]
    /// The hips weren't seen, as on a torso-only manikin, so they were placed from the head and
    /// shoulders. Anything drawn from them is an estimate and draws dashed.
    var torsoEstimated = false

    var torso: TorsoKeypoints {
        TorsoKeypoints(
            leftShoulder: leftShoulder.position,
            rightShoulder: rightShoulder.position,
            leftHip: leftHip.position,
            rightHip: rightHip.position
        )
    }

    var lowestConfidence: Double {
        min(leftShoulder.confidence, rightShoulder.confidence, leftHip.confidence, rightHip.confidence)
    }

    /// A joint Vision really saw. Estimated hips aren't, so no thigh is ever drawn from them.
    func joint(_ name: BodyJoint) -> Joint? {
        switch name {
        case .leftShoulder: leftShoulder
        case .rightShoulder: rightShoulder
        case .leftHip: torsoEstimated ? nil : leftHip
        case .rightHip: torsoEstimated ? nil : rightHip
        default: extras[name]
        }
    }

    /// Every position, estimated hips included. For smoothing, which has to move them all together.
    func mapPositions(_ transform: (BodyJoint, SIMD2<Double>) -> SIMD2<Double>) -> DetectedPerson {
        var person = self
        person.leftShoulder.position = transform(.leftShoulder, leftShoulder.position)
        person.rightShoulder.position = transform(.rightShoulder, rightShoulder.position)
        person.leftHip.position = transform(.leftHip, leftHip.position)
        person.rightHip.position = transform(.rightHip, rightHip.position)
        for (name, joint) in extras {
            person.extras[name]?.position = transform(name, joint.position)
        }
        return person
    }

    /// The nose, or failing that the middle of the eyes or ears. Nil when Vision saw none of them.
    var head: Joint? { Self.head(in: extras) }

    /// Display measured joints only; inferred hips must never look like detections.
    var visibleJoints: [SIMD2<Double>] {
        BodyJoint.allCases.compactMap { name in
            guard let joint = joint(name), joint.confidence >= 0.5,
                  joint.position.x.isFinite, joint.position.y.isFinite,
                  (0...1).contains(joint.position.x), (0...1).contains(joint.position.y)
            else { return nil }
            return joint.position
        }
    }

    var allPositions: [BodyJoint: SIMD2<Double>] {
        var positions = extras.mapValues(\.position)
        positions[.leftShoulder] = leftShoulder.position
        positions[.rightShoulder] = rightShoulder.position
        positions[.leftHip] = leftHip.position
        positions[.rightHip] = rightHip.position
        return positions
    }
}

extension DetectedPerson {
    /// Hips this far below the shoulders, in shoulder widths, and this far across from the midline.
    static let estimatedTorsoLength = 1.25
    static let estimatedHipSpread = 0.8

    /// Hips at least this sure are measured. Below it the selector would turn the body down for low
    /// confidence, so faint hips give way to the estimate, as if they weren't seen at all.
    static let measuredHipConfidence = PatientSelector().minConfidence

    /// From whatever joints Vision saw, in capture image space. Nil without both shoulders, or
    /// without hips or a head to say which way the body runs.
    init?(joints: [BodyJoint: Joint], imageAspect: Double) {
        let seen = joints.filter { $0.value.confidence >= Self.seenConfidence }
        guard let leftShoulder = seen[.leftShoulder], let rightShoulder = seen[.rightShoulder] else { return nil }
        var extras = seen
        for name in [BodyJoint.leftShoulder, .rightShoulder, .leftHip, .rightHip] { extras[name] = nil }
        let hipsSeen = seen[.leftHip].flatMap { left in seen[.rightHip].map { (left: left, right: $0) } }

        if let hips = hipsSeen, min(hips.left.confidence, hips.right.confidence) >= Self.measuredHipConfidence {
            self.init(leftShoulder: leftShoulder, rightShoulder: rightShoulder, leftHip: hips.left, rightHip: hips.right, extras: extras)
            return
        }
        // Hips under a blanket or at the edge of a close chest frame do no better than none.
        if let hips = Self.estimatedHips(leftShoulder: leftShoulder, rightShoulder: rightShoulder, head: Self.head(in: seen), imageAspect: imageAspect) {
            self.init(
                leftShoulder: leftShoulder,
                rightShoulder: rightShoulder,
                leftHip: hips.left,
                rightHip: hips.right,
                extras: extras,
                torsoEstimated: true
            )
            return
        }
        // No head to estimate from: the faint hips are all there is, and the selector judges them.
        guard let hips = hipsSeen else { return nil }
        self.init(leftShoulder: leftShoulder, rightShoulder: rightShoulder, leftHip: hips.left, rightHip: hips.right, extras: extras)
    }

    /// The nose, or failing that the middle of the eyes or ears.
    static func head(in joints: [BodyJoint: Joint]) -> Joint? {
        if let nose = joints[.nose] { return nose }
        for pair in [(BodyJoint.leftEye, BodyJoint.rightEye), (.leftEar, .rightEar)] {
            let found = [joints[pair.0], joints[pair.1]].compactMap { $0 }
            guard !found.isEmpty else { continue }
            let position = found.map(\.position).reduce(.zero, +) / Double(found.count)
            return Joint(position: position, confidence: found.map(\.confidence).min() ?? 0)
        }
        return nil
    }

    /// Head to shoulders gives the body's direction. The hips go where an adult torso would put them.
    private static func estimatedHips(leftShoulder: Joint, rightShoulder: Joint, head: Joint?, imageAspect: Double) -> (left: Joint, right: Joint)? {
        guard let head, imageAspect > 0 else { return nil }
        let iso: (SIMD2<Double>) -> SIMD2<Double> = { [$0.x * imageAspect, $0.y] }
        let capture: (SIMD2<Double>) -> SIMD2<Double> = { [$0.x / imageAspect, $0.y] }
        let left = iso(leftShoulder.position)
        let right = iso(rightShoulder.position)
        let shoulderMid = (left + right) / 2
        let width = simd_length(right - left)
        let neck = shoulderMid - iso(head.position)
        // A head on the shoulder line says nothing about which way the body runs.
        guard width > 0.02, simd_length(neck) >= 0.25 * width else { return nil }
        let hipMid = shoulderMid + simd_normalize(neck) * estimatedTorsoLength * width
        let confidence = min(leftShoulder.confidence, rightShoulder.confidence, head.confidence)
        return (
            Joint(position: capture(hipMid + (left - shoulderMid) * estimatedHipSpread), confidence: confidence),
            Joint(position: capture(hipMid + (right - shoulderMid) * estimatedHipSpread), confidence: confidence)
        )
    }
}

/// Why the latest frame gave no ring.
public enum NoTargetReason: String, Sendable, Equatable {
    case gravityUnknown = "gravity_unknown"
    case noPeople = "no_people"
    case noHorizontalTorso = "no_horizontal_torso"
    case multipleCandidates = "multiple_candidates"
    case lowConfidence = "low_confidence"
    case torsoUnusable = "torso_unusable"
    /// On a limb step: nobody's limb is near the pin, or the only one there is an arm reaching in.
    case notNearPin = "not_near_pin"
}

enum PatientSelection: Sendable, Equatable {
    case patient(DetectedPerson)
    case none(NoTargetReason)
}

/// Picks the one person lying down. No target is always safe here, because voice carries on.
/// All thresholds are demo estimates to tune in M2.
struct PatientSelector: Sendable {
    var minConfidence = 0.3
    /// A lying patient at 45 degrees to a camera pitched down 45 degrees reads about 55 degrees
    /// from gravity in the image, so this can't be close to 90.
    var minDegreesFromGravity = 50.0
    /// Below sin(20 degrees) the camera looks nearly straight down and gravity has no useful
    /// direction in the image.
    var minGravityInPlane = 0.34
    /// Looking down, a standing torso foreshortens along its length while a lying one doesn't.
    var minLengthToWidthLookingDown = 0.9
    /// A body this close to the frame's edge, in normalized image units, with one arm showing is
    /// someone reaching in, not the person being filmed.
    var edgeMargin = 0.06
    /// Fewer joints than this is a detection too thin to trust near a pin.
    var minJointsNearPin = 4

    /// - Parameter gravity: Unit world-down projected on the image plane, in capture image axes.
    ///   Its length is 1 for a level camera and 0 looking straight down.
    func select(people: [DetectedPerson], gravity: SIMD2<Double>?, imageAspect: Double) -> PatientSelection {
        guard let gravity else { return .none(.gravityUnknown) }
        guard !people.isEmpty else { return .none(.noPeople) }

        // Low-confidence people still count here. A shaky second lying body is a reason to doubt
        // the first, while a shaky upright one is not.
        let candidates = people.filter { isHorizontal($0.torso, gravity: gravity, imageAspect: imageAspect) }
        guard candidates.count <= 1 else { return .none(.multipleCandidates) }
        guard let candidate = candidates.first else {
            return .none(people.contains { $0.lowestConfidence < minConfidence } ? .lowConfidence : .noHorizontalTorso)
        }
        guard candidate.lowestConfidence >= minConfidence else { return .none(.lowConfidence) }
        return .patient(candidate)
    }

    /// For a limb step, where the patient may sit or stand: the person whose torso is nearest the
    /// tapped injury. Nearest the torso rather than nearest any joint, so a helper's hand on the
    /// wound doesn't win. Two close candidates still give the nearer one.
    /// - Parameter anchor: The pin in capture image space.
    func selectNearest(people: [DetectedPerson], anchor: SIMD2<Double>, imageAspect: Double) -> PatientSelection {
        guard !people.isEmpty else { return .none(.noPeople) }
        let candidates = people.filter { person in
            let seen = person.allPositions.keys.filter { (person.joint($0)?.confidence ?? 0) >= minConfidence }
            return seen.count >= minJointsNearPin && !isEdgeIntruder(person)
        }
        let iso: (SIMD2<Double>) -> SIMD2<Double> = { [$0.x * imageAspect, $0.y] }
        let point = iso(anchor)
        let nearest = candidates.min { a, b in
            Self.distance(from: point, toQuad: a.torso, iso: iso) < Self.distance(from: point, toQuad: b.torso, iso: iso)
        }
        guard let nearest else { return .none(.notNearPin) }
        return .patient(nearest)
    }

    private func isEdgeIntruder(_ person: DetectedPerson) -> Bool {
        let shoulderMid = (person.leftShoulder.position + person.rightShoulder.position) / 2
        let range = edgeMargin...(1 - edgeMargin)
        guard !range.contains(shoulderMid.x) || !range.contains(shoulderMid.y) else { return false }
        let arms = [[BodyJoint.leftElbow, .leftWrist], [.rightElbow, .rightWrist]].filter { arm in
            arm.contains { (person.joint($0)?.confidence ?? 0) >= minConfidence }
        }
        return arms.count <= 1
    }

    /// Zero inside the torso, else the distance to its nearest edge. Isotropic.
    static func distance(from point: SIMD2<Double>, toQuad torso: TorsoKeypoints, iso: (SIMD2<Double>) -> SIMD2<Double>) -> Double {
        let corners = [torso.leftShoulder, torso.rightShoulder, torso.rightHip, torso.leftHip].map(iso)
        var inside = false
        var nearest = Double.infinity
        for index in corners.indices {
            let a = corners[index]
            let b = corners[(index + 1) % corners.count]
            nearest = min(nearest, distance(from: point, toSegment: a, b))
            // Even-odd crossing, which still gives an answer for a quad whose labels crossed.
            if (a.y > point.y) != (b.y > point.y), point.x < a.x + (point.y - a.y) / (b.y - a.y) * (b.x - a.x) {
                inside.toggle()
            }
        }
        return inside ? 0 : nearest
    }

    static func distance(from point: SIMD2<Double>, toSegment a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let along = b - a
        let lengthSquared = simd_length_squared(along)
        guard lengthSquared > 1e-12 else { return simd_distance(point, a) }
        let t = min(1, max(0, simd_dot(point - a, along) / lengthSquared))
        return simd_distance(point, a + along * t)
    }

    private func isHorizontal(_ torso: TorsoKeypoints, gravity: SIMD2<Double>, imageAspect: Double) -> Bool {
        let isotropic: (SIMD2<Double>) -> SIMD2<Double> = { [$0.x * imageAspect, $0.y] }
        let shoulderMid = (torso.leftShoulder + torso.rightShoulder) / 2
        let hipMid = (torso.leftHip + torso.rightHip) / 2
        let axis = isotropic(hipMid - shoulderMid)
        let length = simd_length(axis)
        guard length > 1e-6 else { return false }

        let gravityLength = simd_length(gravity)
        guard gravityLength >= minGravityInPlane else {
            let width = simd_length(isotropic(torso.rightShoulder - torso.leftShoulder))
            return length >= minLengthToWidthLookingDown * width
        }
        let cosine = min(1, abs(simd_dot(axis, gravity)) / (length * gravityLength))
        return acos(cosine) * 180 / .pi >= minDegreesFromGravity
    }
}
