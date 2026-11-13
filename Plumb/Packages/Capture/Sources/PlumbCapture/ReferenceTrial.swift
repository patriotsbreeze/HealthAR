import Foundation
import PlumbGeometry
import simd

/// Chooses the still reference: watches one point on each side of the hands, level with them,
/// and keeps the side whose depth wavers least. The torso edge or the floor beside the hands
/// should not move; the side with a bystander's knee or a swinging arm in it does.
struct ReferenceTrial: Sendable {
    /// The two world points under watch, left of the hands then right, as the camera sees them.
    let candidates: [SIMD3<Double>]
    private var depths: [[Double]]
    private var startT: TimeInterval?

    /// Starts watching the given points.
    init(candidates: [SIMD3<Double>]) {
        self.candidates = candidates
        depths = candidates.map { _ in [] }
    }

    /// Points `offsetM` either side of `centre`, level with it, along the camera's sideways
    /// direction. Nil when the camera looks straight along the vertical.
    init?(beside centre: SIMD3<Double>, offsetM: Double, pose: CameraPose) {
        guard let side = WorldBox.sideways(of: pose) else { return nil }
        self.init(candidates: [centre - side * offsetM, centre + side * offsetM])
    }

    /// Takes in one frame's depth reading at candidate `index`, nil when it could not be read.
    /// The watch starts with the first frame seen.
    mutating func observe(_ depthM: Double?, candidate index: Int, at t: TimeInterval) {
        if startT == nil { startT = t }
        guard let depthM, depths.indices.contains(index) else { return }
        depths[index].append(depthM)
    }

    /// The chosen point once `durationS` has passed since the watch began: the candidate with the
    /// smallest standard deviation among those read at least `minReadings` times. When neither
    /// qualifies the watch starts over. Nil while still watching.
    mutating func decide(at t: TimeInterval, durationS: TimeInterval, minReadings: Int) -> SIMD3<Double>? {
        guard let startT, t - startT >= durationS else { return nil }
        let scored = depths.indices.compactMap { index in
            depths[index].count >= max(minReadings, 2) ? (index, Self.standardDeviation(depths[index])) : nil
        }
        guard let best = scored.min(by: { $0.1 < $1.1 }) else {
            self.startT = nil
            depths = candidates.map { _ in [] }
            return nil
        }
        return candidates[best.0]
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        let mean = values.reduce(0, +) / Double(values.count)
        let squares = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return (squares / Double(values.count - 1)).squareRoot()
    }
}
