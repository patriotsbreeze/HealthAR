import Foundation
import PlumbContracts

/// One depth reading with its place in the grid. `u` and `v` run from -1 to 1 across the grid.
struct PlaneSample: Sendable {
    var u: Double
    var v: Double
    var depth: Double
}

/// A flat surface as a depth sensor sees it.
///
/// For any plane, however it is tilted to the camera, one over the depth is exactly linear in image
/// position. Fitting that instead of the depth itself is what lets a poster on a wall seen at an
/// angle still measure as flat.
struct InversePlane: Sendable {
    var a: Double
    var b: Double
    var c: Double

    /// The depth of the surface at a grid position, or nil where the plane passes behind the camera.
    func depth(u: Double, v: Double) -> Double? {
        let inverse = a * u + b * v + c
        return inverse > 0 ? 1 / inverse : nil
    }

    /// How far a reading sits in front of the surface, in metres. Negative when it is behind.
    func proudness(of sample: PlaneSample) -> Double {
        (depth(u: sample.u, v: sample.v) ?? .infinity) - sample.depth
    }

    /// The sensor's noise about this surface, in metres, as a standard deviation. Taken from the
    /// middle reading rather than the mean, so an object or clutter covering less than half of the
    /// readings only makes the estimate a little larger, never smaller.
    func noise(in samples: [PlaneSample]) -> Double {
        // For normal noise the median distance from the surface is 0.6745 standard deviations.
        (samples.map { abs(proudness(of: $0)) }.median ?? 0) / 0.6745
    }

    /// Fewer readings than this cannot tell a surface from its outliers.
    private static let minimumSamples = 6
    /// Three-point guesses tried when looking for the main surface. With half of the readings on
    /// it, one guess in eight lands wholly on the surface, so this many all but always find it.
    private static let guesses = 64

    /// The plane through the readings, by least squares.
    static func leastSquares(_ samples: [PlaneSample]) -> InversePlane? {
        guard samples.count >= 3 else { return nil }
        var suu = 0.0, suv = 0.0, su = 0.0, svv = 0.0, sv = 0.0, suw = 0.0, svw = 0.0, sw = 0.0
        for sample in samples {
            let w = 1 / sample.depth
            suu += sample.u * sample.u
            suv += sample.u * sample.v
            su += sample.u
            svv += sample.v * sample.v
            sv += sample.v
            suw += sample.u * w
            svw += sample.v * w
            sw += w
        }
        let n = Double(samples.count)
        // Cramer's rule on the three normal equations.
        let det = suu * (svv * n - sv * sv) - suv * (suv * n - sv * su) + su * (suv * sv - svv * su)
        guard abs(det) > 1e-12 else { return nil }
        let a = (suw * (svv * n - sv * sv) - suv * (svw * n - sv * sw) + su * (svw * sv - svv * sw)) / det
        let b = (suu * (svw * n - sv * sw) - suw * (suv * n - sv * su) + su * (suv * sw - svw * su)) / det
        let c = (suu * (svv * sw - svw * sv) - suv * (suv * sw - svw * su) + suw * (suv * sv - svv * su)) / det
        return InversePlane(a: a, b: b, c: c)
    }

    /// The surface most of the readings lie on, ignoring readings more than `tolerance` metres off
    /// it. Nil when no single flat surface accounts for at least half of the readings.
    ///
    /// A floor with a wall behind it, or a wall with a door frame in view, puts two surfaces in the
    /// readings. A plain fit would settle between them and match neither, so the surface is found
    /// by trying many three-point guesses and keeping the one most readings agree with.
    static func dominant(in samples: [PlaneSample], tolerance: Double) -> InversePlane? {
        guard samples.count >= minimumSamples else { return nil }
        func agreeing(with plane: InversePlane) -> [PlaneSample] {
            samples.filter { abs(plane.proudness(of: $0)) <= tolerance }
        }
        // A fixed seed, so the same readings always give the same surface.
        var random = SplitMix64(seed: 1)
        var best: [PlaneSample] = []
        for _ in 0..<guesses {
            let picks = (0..<3).map { _ in samples[Int(random.next() % UInt64(samples.count))] }
            // Three readings in a line, or the same one twice, define no plane.
            guard let guess = leastSquares(picks) else { continue }
            let support = agreeing(with: guess)
            if support.count > best.count {
                best = support
            }
        }
        // The guess passes through three noisy readings. A fit to everything that agreed with it is
        // steadier, and a second count against that fit picks up readings the guess narrowly missed.
        guard let rough = leastSquares(best) else { return nil }
        let onSurface = agreeing(with: rough)
        guard onSurface.count * 2 >= samples.count else { return nil }
        return leastSquares(onSurface)
    }
}
