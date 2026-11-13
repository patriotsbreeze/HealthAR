import Foundation

/// Where the hands rested before a stroke, and when they left.
struct TopMeasure: Equatable, Sendable {
    var heightMM: Double
    var leftAt: TimeInterval
}

/// Measures the top of a stroke as the average unsmoothed height over the time the hands dwelt there.
///
/// Taking the single highest sample would read high by however large the noise happened to be.
/// Averaging the whole dwell does not, and still follows a top that moves from stroke to stroke.
enum TopDwell {
    /// - Parameters:
    ///   - start: only readings after this time are considered (normally the previous deepest point).
    ///   - bandMM: how far below the highest smoothed reading still counts as being at the top.
    ///   - lagS: how far the smoothed height trails the real one; the dwell is shifted back by this much.
    static func measure(in window: SampleWindow, after start: TimeInterval, bandMM: Double,
                        lagS: Double) -> TopMeasure? {
        var first = 0
        while first < window.count, window[first].t <= start {
            first += 1
        }
        guard first < window.count else { return nil }

        // The highest level that two readings in a row reached. One stray high reading must not set
        // the band, or the dwell would shrink to that reading alone and the top would read high.
        var highest = -Double.infinity
        for index in first..<window.count {
            let here = window[index].smoothMM
            let held = index > 0 ? min(here, window[index - 1].smoothMM) : here
            highest = max(highest, held)
        }
        var arrived = window[first].t
        var left = arrived
        var seen = false
        for index in first..<window.count where window[index].smoothMM >= highest - bandMM {
            if !seen {
                arrived = window[index].t
                seen = true
            }
            left = window[index].t
        }

        // The smoothed height trails the hands, so the hands were in the band a little earlier than it shows.
        let shifted = average(of: window, from: first, between: arrived - lagS, and: left - lagS)
        return shifted ?? average(of: window, from: first, between: arrived, and: left)
    }

    private static func average(of window: SampleWindow, from first: Int, between start: TimeInterval,
                                and end: TimeInterval) -> TopMeasure? {
        var sum = 0.0
        var n = 0
        var last = start
        for index in first..<window.count {
            let point = window[index]
            guard point.t >= start, point.t <= end else { continue }
            sum += point.rawMM
            n += 1
            last = point.t
        }
        return n > 0 ? TopMeasure(heightMM: sum / Double(n), leftAt: last) : nil
    }
}
