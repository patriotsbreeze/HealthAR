import Foundation

/// A chest target from one camera frame.
public struct TimedTorsoTarget: Sendable, Equatable {
    public var target: TorsoTarget
    public var frameID: UInt64
    public var capturedAt: TimeInterval

    public func age(at now: TimeInterval) -> TimeInterval { now - capturedAt }
}

/// Decides whether the chest ring is visible. It only ever outputs show or hide, and nothing
/// waits on it, so AR can't gate a step (invariant 8).
struct RingController: Sendable {
    enum Output: Sendable, Equatable {
        case hidden
        case show(TorsoTarget)
    }

    static let maxKeypointAge: TimeInterval = 0.2

    private var shownFrom: TimeInterval?
    private var shownUntil: TimeInterval?

    /// Shows for the whole step, or until `end` for the hands guide in compressions.
    mutating func enterState(at now: TimeInterval, until end: TimeInterval? = nil) {
        shownFrom = now
        shownUntil = end
    }

    mutating func leaveState() {
        shownFrom = nil
        shownUntil = nil
    }

    func isShowing(at now: TimeInterval) -> Bool {
        guard let shownFrom, now >= shownFrom else { return false }
        return shownUntil.map { now < $0 } ?? true
    }

    func output(latest: TimedTorsoTarget?, at now: TimeInterval) -> Output {
        guard isShowing(at: now), let latest else { return .hidden }
        let age = latest.age(at: now)
        guard age >= 0, age <= Self.maxKeypointAge else { return .hidden }
        return .show(latest.target)
    }
}
