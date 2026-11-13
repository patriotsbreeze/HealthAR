import Foundation

/// Keeps "good" a rare, earned event: given after a fix, or after a long stretch with nothing wrong.
struct PraiseLedger: Equatable, Sendable {
    /// An unbroken stretch of on-target looks.
    private struct Streak: Equatable, Sendable {
        var beganAt: TimeInterval
        var beganAtCount: Int
        var lastSeenAt: TimeInterval
    }

    private var streak: Streak?
    /// True from the moment a correction is shown until the praise for fixing it has been given.
    private var owedForFix = false
    private var lastGivenAt: TimeInterval?
    private var showUntil: TimeInterval?

    /// Notes that a correction is on screen: any praise showing is withdrawn and the fix now has to be earned.
    mutating func interrupt() {
        owedForFix = true
        streak = nil
        showUntil = nil
    }

    /// Ends the current stretch of good work without owing anything, as when a pause is seen.
    mutating func breakStreak() {
        streak = nil
    }

    /// Takes praise off the screen for good, so it cannot reappear after an interruption.
    mutating func hide() {
        showUntil = nil
    }

    /// Takes in the quality of one look. Returns true on the one look where praise is earned.
    mutating func earn(_ quality: Quality, compressions: Int, now: TimeInterval,
                       config: CuePolicy.Config) -> Bool {
        switch quality {
        case .offTarget:
            streak = nil
        case .unseen:
            // A short blind spell is forgiven; after a long one the stretch can no longer be vouched for.
            if let streak, now - streak.lastSeenAt > config.persistS { self.streak = nil }
        case .onTarget:
            if streak == nil { streak = Streak(beganAt: now, beganAtCount: compressions, lastSeenAt: now) }
            streak?.lastSeenAt = now
        }
        guard quality == .onTarget, let streak else { return false }

        let fixed = owedForFix && compressions - streak.beganAtCount >= config.recoveryCompressions
        let unpraisedSince = max(streak.beganAt, lastGivenAt ?? streak.beganAt)
        let steady = now - unpraisedSince >= config.steadyPraiseEveryS
        guard fixed || steady else { return false }

        owedForFix = false
        lastGivenAt = now
        showUntil = now + config.praiseShowS
        return true
    }

    /// Whether praise given a moment ago should still be on screen.
    func isShowing(at now: TimeInterval) -> Bool {
        guard let showUntil else { return false }
        return now < showUntil
    }
}
