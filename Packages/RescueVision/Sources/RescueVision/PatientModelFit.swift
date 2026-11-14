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
                if confidence[i] >= 2, value.isFinite, (0.25...4).contains(value) { values.append(value) }
            }
        }
        guard values.count >= 5 else { return nil }
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

    static func fit(person: DetectedPerson, depth: BodyDepth, camera: CameraPose) -> PatientBodyPlacement? {
        // Never fit a patient to the rescuer, guessed hips, or faint joints.
        guard !person.torsoEstimated, person.lowestConfidence >= 0.5,
              let ls = depth.worldPoint(person.leftShoulder.position, camera: camera),
              let rs = depth.worldPoint(person.rightShoulder.position, camera: camera),
              let lh = depth.worldPoint(person.leftHip.position, camera: camera),
              let rh = depth.worldPoint(person.rightHip.position, camera: camera),
              let target = TorsoMap.target(for: person.torso, imageAspect: camera.imageAspect),
              let chest = depth.worldPoint(target.center, camera: camera)
        else { return nil }
        let shoulders = (ls + rs) / 2, hips = (lh + rh) / 2
        let length = simd_distance(shoulders, hips), width = simd_distance(ls, rs)
        guard (0.25...0.85).contains(length), (0.2...0.65).contains(width),
              simd_distance(lh, rh) > 0.1 else { return nil }
        let headward = simd_normalize(shoulders - hips)
        let acrossRaw = rs - ls - simd_dot(rs - ls, headward) * headward
        guard simd_length(acrossRaw) > 0.15 else { return nil }
        var across = simd_normalize(acrossRaw)
        var normal = simd_normalize(simd_cross(across, headward))
        if simd_dot(normal, camera.position - shoulders) < 0 { normal = -normal; across = -across }
        // A face-up, approximately level adult/manikin. No standing or side-on template.
        guard simd_dot(normal, GhostAnchor.up) >= 0.65,
              abs(simd_dot(headward, GhostAnchor.up)) < 0.5,
              abs(simd_dot(chest - shoulders, normal)) < 0.15,
              abs(simd_dot(lh - shoulders, normal)) < 0.08,
              abs(simd_dot(rh - shoulders, normal)) < 0.08 else { return nil }
        let sx = length / (shouldersX - hipsX), sz = width / shoulderWidth
        let sy = min(sx, sz)
        let origin = shoulders - headward * (shouldersX * sx) - normal * (bodyY * sy)
        let transform = simd_float4x4(columns: (
            SIMD4(headward * sx, 0), SIMD4(normal * sy, 0), SIMD4(across * sz, 0), SIMD4(origin, 1)
        ))
        return PatientBodyPlacement(transform: transform, chest: chest + normal * 0.008, normal: normal)
    }
}
