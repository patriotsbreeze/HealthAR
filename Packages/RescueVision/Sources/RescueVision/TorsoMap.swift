import simd

/// Every image point in this package is in capture image space: normalized to the native
/// camera buffer, origin top-left, y down. Only `DisplayMapping` touches view space.
struct TorsoKeypoints: Sendable, Equatable {
    var leftShoulder: SIMD2<Double>
    var rightShoulder: SIMD2<Double>
    var leftHip: SIMD2<Double>
    var rightHip: SIMD2<Double>
}

/// A coarse palm-sized region, never a precise point.
public struct TorsoTarget: Sendable, Equatable {
    /// Capture image space.
    public var center: SIMD2<Double>
    /// In image heights, because normalized x and y have different scales.
    public var radius: Double
}

/// UNVALIDATED DEMO ESTIMATE. No published work validates sternum location from a phone, and
/// v = 0.22 is our own derivation from one CT study and an assumed torso length. A clinician
/// must confirm this location before it guides anyone. It is a coarse aid that gates nothing.
enum TorsoMap {
    static let alongTorso = 0.22
    /// About 7 cm on a 50 cm torso, which is roughly a palm.
    static let radiusFraction = 0.14
    /// Below this the ring would shrink toward a dot, so give no target. In image heights.
    static let minimumTorsoSize = 0.1
    static let minimumTorsoLength = 0.05

    static func target(for torso: TorsoKeypoints, imageAspect: Double) -> TorsoTarget? {
        guard imageAspect > 0 else { return nil }
        let isotropic: (SIMD2<Double>) -> SIMD2<Double> = { [$0.x * imageAspect, $0.y] }
        let shoulderWidth = simd_length(isotropic(torso.rightShoulder - torso.leftShoulder))
        let shoulderMid = bilinear(torso, u: 0.5, v: 0)
        let hipMid = bilinear(torso, u: 0.5, v: 1)
        let torsoLength = simd_length(isotropic(hipMid - shoulderMid))

        // The larger side survives foreshortening from an oblique view.
        let size = max(shoulderWidth, torsoLength)
        guard size.isFinite, size >= minimumTorsoSize, torsoLength >= minimumTorsoLength else { return nil }
        return TorsoTarget(center: bilinear(torso, u: 0.5, v: alongTorso), radius: size * radiusFraction)
    }

    static func bilinear(_ torso: TorsoKeypoints, u: Double, v: Double) -> SIMD2<Double> {
        let top = simd_mix(torso.leftShoulder, torso.rightShoulder, SIMD2(repeating: u))
        let bottom = simd_mix(torso.leftHip, torso.rightHip, SIMD2(repeating: u))
        return simd_mix(top, bottom, SIMD2(repeating: v))
    }
}
