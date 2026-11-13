import Foundation
import simd

/// The corners and triangles of a flat ring lying in its own x-z plane, centred on the origin and
/// facing +y: a band between two circles, as many corners round as `segments`.
struct RingShape: Sendable, Equatable {
    /// Corners in metres: for each step round, the inner one then the outer one.
    var positions: [SIMD3<Float>]
    /// Corner indices, three to a triangle, wound anticlockwise seen from above (+y).
    var triangles: [UInt32]

    /// A ring from `innerRadiusM` to `outerRadiusM` with `segments` steps round, at least three.
    init(innerRadiusM: Float, outerRadiusM: Float, segments: Int) {
        let steps = max(segments, 3)
        positions = (0..<steps).flatMap { step -> [SIMD3<Float>] in
            let angle = Float(step) / Float(steps) * 2 * .pi
            let direction = SIMD3<Float>(cos(angle), 0, sin(angle))
            return [direction * innerRadiusM, direction * outerRadiusM]
        }
        triangles = (0..<steps).flatMap { step -> [UInt32] in
            let inner = UInt32(2 * step), outer = inner + 1
            let nextInner = UInt32(2 * ((step + 1) % steps)), nextOuter = nextInner + 1
            return [inner, nextInner, outer, outer, nextInner, nextOuter]
        }
    }
}
