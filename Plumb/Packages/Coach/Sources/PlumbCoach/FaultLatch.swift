import Foundation

/// Decides when one kind of fault is real: seen for long enough, then held until it is clearly fixed.
struct FaultLatch: Equatable, Sendable {
    /// First look of the current spell on which the value was out of range.
    private var firstSeenAt: TimeInterval?
    /// Most recent look on which the value was out of range.
    private var lastSeenAt: TimeInterval?
    /// True once the fault has lasted long enough to be believed. Stays true until the value is clearly back in range.
    private(set) var isConfirmed = false

    /// Takes one reading. `margin` is how far outside the target the value is; negative means inside.
    mutating func observe(outsideBy margin: Double, deadBand: Double, persistS: TimeInterval, now: TimeInterval) {
        if margin <= -deadBand {
            clear()
            return
        }
        // Inside the dead band is neither proof of a fault nor proof that it is fixed, so nothing changes.
        // This is what keeps the cue from flickering when the value hovers at a threshold.
        guard margin > deadBand else { return }

        if let lastSeenAt, now - lastSeenAt > persistS {
            // A sighting that was not backed up within the window is too old to count towards this spell.
            firstSeenAt = nil
        }
        let spellBegan = firstSeenAt ?? now
        firstSeenAt = spellBegan
        lastSeenAt = now
        if now - spellBegan >= persistS { isConfirmed = true }
    }

    /// Forgets the fault and any suspicion of it.
    mutating func clear() {
        self = FaultLatch()
    }
}
