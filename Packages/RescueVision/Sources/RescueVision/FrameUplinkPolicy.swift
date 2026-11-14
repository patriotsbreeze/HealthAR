import Foundation

/// Rate gate for frames going to the model. Closed until the engine opens it, so an unset
/// policy sends nothing (invariant 11).
struct FrameUplinkPolicy: Sendable {
    static let burstDuration: TimeInterval = 3
    static let baseBurstInterval: TimeInterval = 1
    /// One a second, the rate Live takes video at, so what it reports on screen is the scene now and
    /// not five seconds ago. Awake steps are bursts only, so this only runs where frames are open.
    static let baseIdleInterval: TimeInterval = 1
    /// Heat can stretch it this far and no further.
    static let maxIdleInterval: TimeInterval = 4

    private(set) var isOpen = false
    private var burstEndsAt: TimeInterval?
    private var lastSentAt: TimeInterval?
    private var intervalScale = 1.0
    private var burstsOnly = false

    /// Pass `RuntimePolicy.frameUplink`.
    mutating func setOpen(_ open: Bool) {
        isOpen = open
        if !open { burstEndsAt = nil }
    }

    /// Pass `RuntimePolicy.frameBurstsOnly`. Takes away the idle rate, and nothing else.
    mutating func setBurstsOnly(_ only: Bool) {
        burstsOnly = only
    }

    /// Thermal shedding only ever stretches the intervals.
    mutating func setIntervalScale(_ scale: Double) {
        intervalScale = max(1, scale)
    }

    mutating func beginBurst(at now: TimeInterval) {
        guard isOpen else { return }
        burstEndsAt = now + Self.burstDuration
    }

    /// True means send this frame, and the send is counted.
    mutating func shouldSend(at now: TimeInterval) -> Bool {
        guard isOpen else { return false }
        if burstsOnly, !inBurst(at: now) { return false }
        if let lastSentAt, now - lastSentAt < interval(at: now) { return false }
        lastSentAt = now
        return true
    }

    private func inBurst(at now: TimeInterval) -> Bool {
        burstEndsAt.map { now < $0 } ?? false
    }

    private func interval(at now: TimeInterval) -> TimeInterval {
        if inBurst(at: now) { return Self.baseBurstInterval * intervalScale }
        return min(Self.baseIdleInterval * intervalScale, Self.maxIdleInterval)
    }
}
