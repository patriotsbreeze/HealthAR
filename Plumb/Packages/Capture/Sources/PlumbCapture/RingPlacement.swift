import Foundation
import simd

/// Where the ring lies on the chest: at the hands box centre, flat on the surface there.
struct RingPlacement: Sendable, Equatable {
    /// Centre of the ring in the world, in metres: the hands box centre, which the depth map put
    /// on the surface it was placed on.
    var centre: SIMD3<Double>
    /// Unit normal of the surface the ring lies on, on its upper side.
    var normal: SIMD3<Double>

    /// World up, which the ring lies square to when the surface cannot be trusted.
    static let up = SIMD3<Double>(0, 1, 0)

    /// The ring at `centre`, lying on the plane fitted to `points` when that fit is one surface and
    /// near enough level to be a chest lying down; otherwise level, square to gravity. Fewer than
    /// `minPoints` points, a fit rougher than `maxRoughnessM` (an arm or the edge of the cushion in
    /// the window) or one leaning more than `maxTiltRadians` all give level.
    static func fitted(at centre: SIMD3<Double>, to points: [SIMD3<Double>], minPoints: Int,
                       maxTiltRadians: Double, maxRoughnessM: Double) -> RingPlacement {
        let level = RingPlacement(centre: centre, normal: up)
        guard points.count >= minPoints, let fit = SurfaceFit(points), fit.roughnessM <= maxRoughnessM else {
            return level
        }
        let normal = fit.normal.y < 0 ? -fit.normal : fit.normal
        guard acos(min(normal.y, 1)) <= maxTiltRadians else { return level }
        return RingPlacement(centre: centre, normal: normal)
    }

    /// The turn that takes the ring's own up, +y, onto the surface normal.
    var rotation: simd_quatf {
        simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(SIMD3<Float>(normal)))
    }
}
