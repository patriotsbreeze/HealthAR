import Foundation
import PlumbContracts

/// Remembers when the signal last came back, so nothing is concluded from the first moments after a loss.
struct SignalWatch: Equatable, Sendable {
    private var isLost = false
    /// When the signal was last seen to return after being lost. Nil if it has never been lost.
    private var returnedAt: TimeInterval?

    /// Takes in the lock state of one look, and any loss the events say happened since the last look.
    mutating func note(lock: LockState, events: [SignalEvent], now: TimeInterval) {
        if lock == .lost {
            isLost = true
            return
        }
        // A loss short enough to fall between two looks still counts as a loss.
        let blinked = events.contains { event in
            if case .lockChanged(.lost, at: _) = event { return true }
            return false
        }
        if isLost || blinked { returnedAt = now }
        isLost = false
    }

    /// True when there is a signal and it has been back for long enough to trust what it says about a pause.
    func isSteady(at now: TimeInterval, settleS: TimeInterval) -> Bool {
        guard !isLost else { return false }
        guard let returnedAt else { return true }
        return now - returnedAt >= settleS
    }
}
