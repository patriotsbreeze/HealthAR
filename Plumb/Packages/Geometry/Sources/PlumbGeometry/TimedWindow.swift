import Foundation

/// The values seen in the last few seconds, for running medians and spreads.
struct TimedWindow: Sendable {
    /// How many seconds of history are kept.
    let spanS: TimeInterval
    private var times: [TimeInterval] = []
    private var values: [Double] = []

    init(spanS: TimeInterval) {
        self.spanS = spanS
    }

    var count: Int { values.count }

    var median: Double? { Stats.median(values) }

    var standardDeviation: Double? { Stats.standardDeviation(values) }

    /// Adds a value seen at time `t` and forgets whatever is now too old.
    mutating func add(_ value: Double, at t: TimeInterval) {
        advance(to: t)
        times.append(t)
        values.append(value)
    }

    /// Forgets whatever is too old at time `t`, without adding anything.
    mutating func advance(to t: TimeInterval) {
        // A clock that steps backwards means a new recording; old values would never age out.
        if let newest = times.last, newest > t {
            times.removeAll()
            values.removeAll()
        }
        let stale = times.firstIndex { $0 > t - spanS } ?? times.count
        times.removeFirst(stale)
        values.removeFirst(stale)
    }
}
