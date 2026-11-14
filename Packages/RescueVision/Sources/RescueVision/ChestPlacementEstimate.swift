import Foundation
import simd

/// A visual hand-placement estimate, not anatomical sternum recognition.
public struct ChestSurfacePlacement: Sendable, Equatable {
    public var center: SIMD3<Float>
    public var normal: SIMD3<Float>
}

struct TimedChestEstimate: Sendable {
    var target: TorsoTarget
    /// The torso the target came from, for which way is headward when guiding a hand onto it.
    var torso: TorsoKeypoints
    var surface: ChestSurfacePlacement?
    var capturedAt: TimeInterval

    static func estimate(person: DetectedPerson, depth: BodyDepth?, record: FrameRecord) -> TimedChestEstimate? {
        // Hips estimated from the head and shoulders are allowed, as in PatientModelFit: a lying
        // body seen from above rarely shows confident hips, least of all with hands on its chest.
        guard record.tracking == .normal, person.lowestConfidence >= 0.3,
              let target = TorsoMap.target(for: person.torso, imageAspect: record.pose.imageAspect) else { return nil }
        // No mesh, hip depth, or model asset is needed for the image-space estimate.
        let surface = depth?.worldPoint(target.center, camera: record.pose).flatMap { point -> ChestSurfacePlacement? in
            let towardCamera = record.pose.position - point
            guard simd_length(towardCamera) > 0.1 else { return nil }
            let normal = simd_normalize(towardCamera)
            return ChestSurfacePlacement(center: point + normal * 0.008, normal: normal)
        }
        return TimedChestEstimate(target: target, torso: person.torso, surface: surface, capturedAt: record.timestamp)
    }
}
