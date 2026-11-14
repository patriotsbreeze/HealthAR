import Foundation
import simd

/// The tracked patient's arms and legs as soft pieces for the body surface. Each joint eases toward its
/// newest depth point, so the limbs glide rather than jump with the tracker, and a limb missing for a
/// moment holds briefly, then thins away instead of popping off.
struct TrackedLimbs {
    /// Shoulder-elbow-wrist and hip-knee-ankle. A missing middle joint never gets bridged by a straight
    /// line: a chain only draws the segments that were measured.
    static let chains: [(BodyJoint, BodyJoint, BodyJoint)] = [
        (.leftShoulder, .leftElbow, .leftWrist), (.rightShoulder, .rightElbow, .rightWrist),
        (.leftHip, .leftKnee, .leftAnkle), (.rightHip, .rightKnee, .rightAnkle),
    ]
    /// How long a segment holds after its last measurement before it starts to thin away.
    static let grace: TimeInterval = 0.25
    /// Seconds for a joint to cover most of the way to a new reading.
    static let follow: Float = 0.09
    /// Seconds for a limb to grow in or thin away.
    static let fade: Float = 0.12
    /// Depth lands on the near surface of a limb; its centre line sits this share of a radius further on.
    static let surfaceToCentre: Float = 0.6

    private struct Segment: Hashable { var from: BodyJoint; var to: BodyJoint }
    private struct Shape { var a, b: SIMD3<Float>; var r1, r2: Float }

    private var joints: [BodyJoint: SIMD3<Float>] = [:]
    private var seen: [Segment: TimeInterval] = [:]
    private var radius: [Segment: Float] = [:]
    private var presence = [Float](repeating: 0, count: chains.count)
    private var shapes: [[Shape]] = Array(repeating: [], count: chains.count)
    private var lastTime: TimeInterval?
    /// Limbs in the last output, for the log.
    private(set) var drawn = 0

    /// Forget every joint, so the next sighting snaps into place instead of gliding from an old one.
    mutating func reset() {
        self = TrackedLimbs()
    }

    mutating func update(_ limbs: [TrackedBodyLimb], camera: SIMD3<Float>?, now: TimeInterval) -> [BodyPiece] {
        let dt = Float(min(lastTime.map { now - $0 } ?? 0, 0.1))
        lastTime = now
        let ease = 1 - exp(-dt / Self.follow), grow = 1 - exp(-dt / Self.fade)

        var targets: [BodyJoint: SIMD3<Float>] = [:]
        for limb in limbs {
            let segment = Segment(from: limb.from, to: limb.to)
            seen[segment] = now
            radius[segment] = limb.radius
            targets[limb.from] = Self.centre(limb.start, radius: limb.radius, camera: camera)
            targets[limb.to] = Self.centre(limb.end, radius: limb.radius, camera: camera)
        }
        for (joint, target) in targets {
            joints[joint] = joints[joint].map { simd_mix($0, target, SIMD3(repeating: ease)) } ?? target
        }

        var pieces: [BodyPiece] = []
        drawn = 0
        for (i, chain) in Self.chains.enumerated() {
            let upper = Segment(from: chain.0, to: chain.1), lower = Segment(from: chain.1, to: chain.2)
            let upperLive = seen[upper].map { now - $0 < Self.grace } ?? false
            let lowerLive = seen[lower].map { now - $0 < Self.grace } ?? false
            presence[i] += ((upperLive || lowerLive ? 1 : 0) - presence[i]) * grow
            if upperLive || lowerLive {
                // While it thins away the limb keeps the last shape it had.
                let ru = radius[upper] ?? radius[lower] ?? 0.04, rl = radius[lower] ?? ru
                let middle = (ru + rl) / 2 * 0.95
                var shape: [Shape] = []
                if upperLive, let a = joints[chain.0], let b = joints[chain.1] { shape.append(Shape(a: a, b: b, r1: ru, r2: middle)) }
                if lowerLive, let b = joints[chain.1], let c = joints[chain.2] { shape.append(Shape(a: b, b: c, r1: middle, r2: rl * 0.75)) }
                shapes[i] = shape
            } else if presence[i] < 0.02 {
                shapes[i] = []
                for j in [chain.0, chain.1, chain.2] { joints[j] = nil }
            }
            guard presence[i] >= 0.02, !shapes[i].isEmpty else { continue }
            drawn += 1
            for s in shapes[i] {
                pieces.append(.cone(from: s.a, to: s.b, r1: s.r1 * presence[i], r2: s.r2 * presence[i]))
            }
        }
        return pieces
    }

    /// The measured surface point moved back along the camera's line of sight to the limb's middle.
    private static func centre(_ surface: SIMD3<Float>, radius: Float, camera: SIMD3<Float>?) -> SIMD3<Float> {
        guard let camera, simd_distance(surface, camera) > 0.05 else { return surface }
        return surface + simd_normalize(surface - camera) * (radius * surfaceToCentre)
    }
}
