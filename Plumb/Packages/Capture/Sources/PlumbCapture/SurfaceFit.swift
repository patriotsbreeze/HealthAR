import Foundation
import simd

/// The flat surface that best fits a cloud of world points: the plane through their centroid
/// that the points stray least from, and how far, root mean square, they stray.
struct SurfaceFit: Sendable, Equatable {
    /// Unit normal of the plane. Its sign is arbitrary.
    var normal: SIMD3<Double>
    /// Root mean square distance of the points from the plane, in metres.
    var roughnessM: Double

    /// Fits a plane to `points`. Nil for fewer than three points.
    ///
    /// The normal is the direction the points spread least along: the eigenvector of their
    /// covariance with the smallest eigenvalue. It is found by power iteration on (trace - covariance),
    /// whose largest eigenvalue belongs to that same eigenvector, since the covariance's eigenvalues
    /// are never negative and its trace is their sum.
    init?(_ points: [SIMD3<Double>]) {
        guard points.count >= 3 else { return nil }
        let centroid = points.reduce(SIMD3<Double>.zero, +) / Double(points.count)
        var covariance = simd_double3x3()
        for point in points {
            let offset = point - centroid
            covariance += simd_double3x3(columns: (offset * offset.x, offset * offset.y, offset * offset.z))
        }
        covariance *= 1 / Double(points.count)
        let trace = covariance[0][0] + covariance[1][1] + covariance[2][2]
        let flipped = simd_double3x3(diagonal: SIMD3(repeating: trace)) - covariance
        // Leans away from every axis, so no plane's normal can be square to where it starts.
        var normal = simd_normalize(SIMD3<Double>(0.3, 1, 0.2))
        for _ in 0..<Self.iterations {
            let next = flipped * normal
            let length = simd_length(next)
            // Every point the same: no plane to speak of.
            guard length > 1e-15 else { return nil }
            normal = next / length
        }
        self.normal = normal
        roughnessM = max(simd_dot(normal, covariance * normal), 0).squareRoot()
    }

    /// Enough for the worst ratio a patch of a surface gives (a square patch halves the error
    /// each step) to settle far below anything a depth map could tell apart.
    private static let iterations = 64
}
