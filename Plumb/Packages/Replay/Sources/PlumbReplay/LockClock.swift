import Foundation
import PlumbContracts

/// Adds up how long the analyzer spent in each trust state, from the changes it reported.
struct LockClock: Sendable {
    private var state = LockState.lost
    private var since: TimeInterval?
    private var seconds: [LockState: Double] = [:]

    /// Starts the clock at the first frame, in the state the analyzer starts in.
    mutating func start(at t: TimeInterval) {
        since = since ?? t
    }

    /// Records a change reported by the analyzer. It reports them in time order.
    mutating func change(to next: LockState, at t: TimeInterval) {
        close(at: t)
        state = next
    }

    /// Seconds spent locked up to `end`.
    func lockedSeconds(until end: TimeInterval) -> Double {
        var copy = self
        copy.close(at: end)
        return copy.seconds[.locked, default: 0]
    }

    private mutating func close(at t: TimeInterval) {
        guard let from = since else { return }
        seconds[state, default: 0] += max(0, t - from)
        since = max(from, t)
    }
}

/// The analyzer's tick times: an even beat from the first frame on, as the app's ten-a-second timer.
struct TickClock: Sendable {
    private let stepS: Double
    private var next: TimeInterval?

    init(ticksPerSecond: Double) {
        stepS = ticksPerSecond > 0 ? 1 / ticksPerSecond : .infinity
    }

    /// Tick times that fall before `t`, each given once.
    mutating func due(before t: TimeInterval) -> [TimeInterval] {
        guard stepS.isFinite else { return [] }
        var tick = next ?? t
        var times: [TimeInterval] = []
        while tick < t {
            times.append(tick)
            tick += stepS
        }
        next = tick
        return times
    }
}
