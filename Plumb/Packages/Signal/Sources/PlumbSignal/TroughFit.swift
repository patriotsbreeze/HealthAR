import Foundation

/// The deepest point of a stroke: how low, and when.
struct BottomMeasure: Equatable, Sendable {
    var heightMM: Double
    var t: TimeInterval
    /// Plain average height of the readings around the deepest point. One low reading barely moves it.
    var surroundMM: Double
}

/// Measures the deepest point by fitting a parabola through the unsmoothed readings around it.
///
/// Smoothing rounds off the sharp turn at the bottom and makes a stroke look shallower.
/// A fitted curve averages the noise without doing that, and places the turn between samples.
enum TroughFit {
    /// - Parameters:
    ///   - start: when the stroke began; the lowest reading since then anchors the fit.
    ///   - halfWindowS: readings within this long either side of that lowest reading are fitted.
    static func measure(in window: SampleWindow, since start: TimeInterval,
                        halfWindowS: Double) -> BottomMeasure? {
        var lowest: TracePoint?
        for index in 0..<window.count {
            let point = window[index]
            if point.t >= start, point.rawMM < (lowest?.rawMM ?? .infinity) {
                lowest = point
            }
        }
        guard let lowest, halfWindowS > 0 else { return nil }

        // Time is rescaled to about -1...1 around the lowest reading so the sums stay well conditioned.
        var sums = Sums()
        for index in 0..<window.count {
            let point = window[index]
            let u = (point.t - lowest.t) / halfWindowS
            if abs(u) <= 1 {
                sums.add(u: u, h: point.rawMM)
            }
        }
        let surround = sums.h / sums.n
        guard sums.n >= 3, let curve = sums.parabola() else {
            return BottomMeasure(heightMM: lowest.rawMM, t: lowest.t, surroundMM: surround)
        }
        guard curve.bend > 0 else {
            // No turn to find: the hands were held flat, so the level is the plain average.
            return BottomMeasure(heightMM: surround, t: lowest.t, surroundMM: surround)
        }
        // The turning point, kept inside the readings that were fitted so the curve is never extrapolated.
        let u = min(max(-curve.slope / (2 * curve.bend), sums.uMin), sums.uMax)
        let height = curve.level + curve.slope * u + curve.bend * u * u
        return BottomMeasure(heightMM: height, t: lowest.t + u * halfWindowS, surroundMM: surround)
    }

    /// A parabola `level + slope·u + bend·u²`.
    private struct Curve {
        var level: Double
        var slope: Double
        var bend: Double
    }

    /// Running sums for a least-squares parabola.
    private struct Sums {
        var n = 0.0
        var u1 = 0.0, u2 = 0.0, u3 = 0.0, u4 = 0.0
        var h = 0.0, hu = 0.0, hu2 = 0.0
        var uMin = Double.infinity
        var uMax = -Double.infinity

        mutating func add(u: Double, h height: Double) {
            let uu = u * u
            n += 1
            u1 += u
            u2 += uu
            u3 += uu * u
            u4 += uu * uu
            h += height
            hu += height * u
            hu2 += height * uu
            uMin = min(uMin, u)
            uMax = max(uMax, u)
        }

        /// Solves the three normal equations by Cramer's rule. Nil when the readings do not pin down a parabola.
        func parabola() -> Curve? {
            let det = n * (u2 * u4 - u3 * u3) - u1 * (u1 * u4 - u3 * u2) + u2 * (u1 * u3 - u2 * u2)
            guard abs(det) > 1e-9 else { return nil }
            let level = h * (u2 * u4 - u3 * u3) - u1 * (hu * u4 - u3 * hu2) + u2 * (hu * u3 - u2 * hu2)
            let slope = n * (hu * u4 - u3 * hu2) - h * (u1 * u4 - u3 * u2) + u2 * (u1 * hu2 - hu * u2)
            let bend = n * (u2 * hu2 - hu * u3) - u1 * (u1 * hu2 - hu * u2) + h * (u1 * u3 - u2 * u2)
            return Curve(level: level / det, slope: slope / det, bend: bend / det)
        }
    }
}
