import Foundation
import simd

/// A visual hand-placement estimate, not anatomical sternum recognition.
public struct ChestSurfacePlacement: Sendable, Equatable {
    public var center: SIMD3<Float>
    public var normal: SIMD3<Float>
}

struct TimedChestEstimate: Sendable {
    var target: TorsoTarget
    var surface: ChestSurfacePlacement?
    var capturedAt: TimeInterval

    static func estimate(person: DetectedPerson, depth: BodyDepth?, record: FrameRecord) -> TimedChestEstimate? {
        guard record.tracking == .normal, !person.torsoEstimated, person.lowestConfidence >= 0.5,
              let target = TorsoMap.target(for: person.torso, imageAspect: record.pose.imageAspect) else { return nil }
        // No mesh, hip depth, or model asset is needed for the image-space estimate.
        let surface = depth?.worldPoint(target.center, camera: record.pose).flatMap { point -> ChestSurfacePlacement? in
            let towardCamera = record.pose.position - point
            guard simd_length(towardCamera) > 0.1 else { return nil }
            let normal = simd_normalize(towardCamera)
            return ChestSurfacePlacement(center: point + normal * 0.008, normal: normal)
        }
        return TimedChestEstimate(target: target, surface: surface, capturedAt: record.timestamp)
    }
}
