import Foundation
import simd

/// The slow ruler: where the hands have stood on the floor plan over the last second.
///
/// Hands doing compressions go up and down, so their world x and z barely change during a stroke,
/// while their distance from a tilted camera swings with every push. Taking the median of the
/// floor-plan position, not of the range, gives a ruler that stays put through the stroke.
struct FloorRuler: Sendable {
    private var x: TimedWindow
    private var z: TimedWindow

    init(spanS: TimeInterval) {
        x = TimedWindow(spanS: spanS)
        z = TimedWindow(spanS: spanS)
    }

    /// The median floor-plan position as (world x, world z). Nil until the hands have been placed once.
    var spot: SIMD2<Double>? {
        guard let medianX = x.median, let medianZ = z.median else { return nil }
        return SIMD2(medianX, medianZ)
    }

    /// Takes in where the hands were placed in the world for the frame at time `t`.
    mutating func add(_ point: SIMD3<Double>, at t: TimeInterval) {
        x.add(point.x, at: t)
        z.add(point.z, at: t)
    }

    /// Marks a frame at time `t` in which the hands could not be placed.
    mutating func advance(to t: TimeInterval) {
        x.advance(to: t)
        z.advance(to: t)
    }
}
