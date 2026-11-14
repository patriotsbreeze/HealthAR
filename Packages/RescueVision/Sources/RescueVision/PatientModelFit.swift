import Foundation
import simd

/// A bounded, immutable copy of scene depth from the same ARFrame as the camera image.
/// Depth is camera-z metres, in native capture orientation. Never uploaded.
struct BodyDepth: Sendable {
    var width: Int
    var height: Int
    var metres: [Float]
    var confidence: [UInt8]

    func sample(_ point: SIMD2<Double>) -> Float? {
        guard width >= 3, height >= 3, metres.count == width * height,
              confidence.count == metres.count,
              point.x.isFinite, point.y.isFinite,
              (0..<1).contains(point.x), (0..<1).contains(point.y) else { return nil }
        let x = Int(point.x * Double(width)), y = Int(point.y * Double(height))
        guard x > 0, y > 0, x < width - 1, y < height - 1 else { return nil }
        var values: [Float] = []
        for row in (y - 1)...(y + 1) {
            for column in (x - 1)...(x + 1) {
                let i = row * width + column, value = metres[i]
                if confidence[i] >= 1, value.isFinite, (0.25...4).contains(value) { values.append(value) }
            }
        }
        guard values.count >= 4 else { return nil }
        values.sort()
        // A boundary between the body and the floor is not a trustworthy surface sample.
        guard values[values.count - 1] - values[0] < 0.08 else { return nil }
        return values[values.count / 2]
    }

    func worldPoint(_ point: SIMD2<Double>, camera: CameraPose) -> SIMD3<Float>? {
        guard let z = sample(point) else { return nil }
        let cameraPoint = SIMD4<Float>(
            (Float(point.x * camera.imageResolution.x) - camera.intrinsics.columns.2.x) * z / camera.intrinsics.columns.0.x,
            -(Float(point.y * camera.imageResolution.y) - camera.intrinsics.columns.2.y) * z / camera.intrinsics.columns.1.y,
            -z, 1
        )
        let world = (camera.transform * cameraPoint).xyz
        guard world.x.isFinite, world.y.isFinite, world.z.isFinite else { return nil }
        return world
    }
}

/// A fitted template, not a measured body surface or anatomical sternum detection.
public struct PatientBodyPlacement: Sendable, Equatable {
    /// Blender model space to world, with independent torso length/width scales.
    public var transform: simd_float4x4
    /// Coarse chest-surface estimate from the existing TorsoMap, never an identified bone.
    public var chest: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var showsChestEstimate: Bool = false
    /// Fitted to a face-up, level body. Only then may the chest estimate show.
    public var lying: Bool = true
    /// Centre of the real head in the world, from depth at the face. Nil when no head was seen, and
    /// the template head stands in.
    public var head: SIMD3<Float>? = nil
    /// Independently measured limbs of this person; missing endpoints produce no segment.
    public var limbs: [TrackedBodyLimb] = []
}

public struct TrackedBodyLimb: Sendable, Equatable {
    public var from: BodyJoint
    public var to: BodyJoint
    public var start: SIMD3<Float>
    public var end: SIMD3<Float>
    public var radius: Float
}

struct TimedPatientBody: Sendable {
    var placement: PatientBodyPlacement
    var capturedAt: TimeInterval
}

enum PatientModelFit {
    /// Values from patient() in tools/make_ghost_model.py, in exported model metres.
    static let shouldersX: Float = 0.16
    static let hipsX: Float = -0.42
    static let shoulderWidth: Float = 0.4
    static let bodyY: Float = -0.1
    /// Template head centre and half-depth, from HEAD_CENTER and HEAD_SIZE in the same script.
    public static let headCenter = SIMD3<Float>(0.42, -0.09, 0)
    static let headHalfDepth: Float = 0.08
    /// The nearest and farthest a head centre may sit from the middle of the shoulders.
    static let headReach: ClosedRange<Float> = 0.1...0.45

    /// - Parameter requireLying: When false, any single person's torso is fitted, in whatever pose,
    ///   and the result is marked as not lying so no chest estimate shows on it.
    static func fit(person: DetectedPerson, depth: BodyDepth, camera: CameraPose, requireLying: Bool = true) -> PatientBodyPlacement? {
        // Never fit a patient to the rescuer or faint joints. Hips estimated from the shoulders and head
        // are allowed: a lying body seen from above rarely shows confident hips, and the depth and
        // planarity checks below still turn down a guess that doesn't sit on the body.
        guard person.lowestConfidence >= 0.3 else { return nil }
        guard let ls = depth.worldPoint(person.leftShoulder.position, camera: camera) else { return nil }
        guard let rs = depth.worldPoint(person.rightShoulder.position, camera: camera) else { return nil }
        guard let lh = depth.worldPoint(person.leftHip.position, camera: camera) else { return nil }
        guard let rh = depth.worldPoint(person.rightHip.position, camera: camera) else { return nil }
        guard let target = TorsoMap.target(for: person.torso, imageAspect: camera.imageAspect) else { return nil }
        guard let chest = depth.worldPoint(target.center, camera: camera) else { return nil }
        let shoulders = (ls + rs) / 2, hips = (lh + rh) / 2
        let length = simd_distance(shoulders, hips), width = simd_distance(ls, rs)
        guard (0.25...0.85).contains(length) else { return nil }
        guard (0.2...0.65).contains(width) else { return nil }
        guard simd_distance(lh, rh) > 0.1 else { return nil }
        let headward = simd_normalize(shoulders - hips)
        let acrossRaw = rs - ls - simd_dot(rs - ls, headward) * headward
        guard simd_length(acrossRaw) > 0.15 else { return nil }
        // Which way the chest faces comes from gravity, not from the two shoulder depths: one of those
        // landing on the floor or a spread arm tips it, and the body draws rolled onto its side. A body
        // lying roughly level faces up; an upright one faces the camera.
        let flat = abs(simd_dot(headward, GhostAnchor.up)) < 0.5
        let reference = flat ? GhostAnchor.up : camera.position - shoulders
        let normalRaw = reference - simd_dot(reference, headward) * headward
        guard simd_length(normalRaw) > 1e-3 else { return nil }
        let normal = simd_normalize(normalRaw)
        // Head, chest-out, across: the same right-handed frame as before, so nothing renders mirrored.
        let across = simd_cross(headward, normal)
        // A face-up, approximately level adult/manikin, unless any pose is allowed.
        let lying = flat
        guard lying || !requireLying else { return nil }
        guard abs(simd_dot(chest - shoulders, normal)) < 0.15 else { return nil }
        // A standing or twisting body's hips sit well off its shoulder plane; a lying one's don't.
        let hipTolerance: Float = requireLying ? 0.08 : 0.2
        guard abs(simd_dot(lh - shoulders, normal)) < hipTolerance else { return nil }
        guard abs(simd_dot(rh - shoulders, normal)) < hipTolerance else { return nil }
        let sx = length / (shouldersX - hipsX), sz = width / shoulderWidth
        let sy = min(sx, sz)
        let origin = shoulders - headward * (shouldersX * sx) - normal * (bodyY * sy)
        let transform = simd_float4x4(columns: (
            SIMD4(headward * sx, 0), SIMD4(normal * sy, 0), SIMD4(across * sz, 0), SIMD4(origin, 1)
        ))
        var placement = PatientBodyPlacement(transform: transform, chest: chest + normal * 0.008, normal: normal, lying: lying)
        placement.head = head(of: person, depth: depth, camera: camera, shoulders: shoulders, scale: sy)
        placement.limbs = limbs(of: person, depth: depth, camera: camera, scale: sy)
        return placement
    }

    /// The same limb radii as the Blender patient, driven by this observation's actual endpoints.
    static func limbs(of person: DetectedPerson, depth: BodyDepth, camera: CameraPose, scale: Float) -> [TrackedBodyLimb] {
        let chains: [(BodyJoint, BodyJoint, Float, ClosedRange<Float>)] = [
            (.leftShoulder, .leftElbow, 0.047, 0.08...0.65),
            (.leftElbow, .leftWrist, 0.037, 0.07...0.6),
            (.rightShoulder, .rightElbow, 0.047, 0.08...0.65),
            (.rightElbow, .rightWrist, 0.037, 0.07...0.6),
            (.leftHip, .leftKnee, 0.075, 0.12...0.8),
            (.leftKnee, .leftAnkle, 0.05, 0.12...0.8),
            (.rightHip, .rightKnee, 0.075, 0.12...0.8),
            (.rightKnee, .rightAnkle, 0.05, 0.12...0.8),
        ]
        return chains.compactMap { from, to, radius, lengths in
            guard let a = person.joint(from), let b = person.joint(to),
                  a.confidence >= 0.3, b.confidence >= 0.3,
                  let start = depth.worldPoint(a.position, camera: camera),
                  let end = depth.worldPoint(b.position, camera: camera),
                  lengths.contains(simd_distance(start, end)) else { return nil }
            return TrackedBodyLimb(from: from, to: to, start: start, end: end, radius: radius * min(1.5, max(0.6, scale)))
        }
    }

    /// Depth at the face is its surface, so the centre sits a head's half-depth further from the camera.
    static func head(of person: DetectedPerson, depth: BodyDepth, camera: CameraPose, shoulders: SIMD3<Float>, scale: Float) -> SIMD3<Float>? {
        guard let joint = DetectedPerson.head(in: person.extras), joint.confidence >= 0.3,
              let face = depth.worldPoint(joint.position, camera: camera) else { return nil }
        let center = face + simd_normalize(face - camera.position) * headHalfDepth * scale
        guard headReach.contains(simd_distance(center, shoulders)) else {
            return nil
        }
        return center
    }
}
