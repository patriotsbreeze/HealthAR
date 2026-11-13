import Foundation
import PlumbContracts

/// Builds the only view of the rescue a model is given: the live numbers, how old they are,
/// and whether they are fit to answer from.
public enum WorldDigestBuilder {
    /// The digest of `metrics` as seen at session time `now`. It is stale when older than
    /// `staleAfterS` or when the lock is lost, and it carries depth only while the lock is `locked`.
    public static func make(metrics: Metrics, now: TimeInterval,
                            staleAfterS: Double = SessionConfig.standard.staleAfterS) -> WorldDigest {
        let age = ageS(of: metrics, at: now)
        // Asked as "is it fresh" so that a limit that is not a number can never pass old data as fresh.
        let isFresh = age <= staleAfterS
        let depthIsTrusted = metrics.lock == .locked
        return WorldDigest(
            lock: metrics.lock,
            count: metrics.count,
            ratePerMin: metrics.ratePerMin,
            depthMM: depthIsTrusted ? metrics.depthMM : nil,
            depthSpreadMM: depthIsTrusted ? metrics.depthSpreadMM : nil,
            isPaused: metrics.isPaused,
            pauseSeconds: metrics.pauseSeconds,
            handsOnFraction: metrics.handsOnFraction,
            ageS: age,
            stale: !isFresh || metrics.lock == .lost)
    }

    /// Seconds since the numbers were measured, never negative. An age that cannot be worked out
    /// is reported as the largest finite number: always stale, and still safe to write as JSON.
    private static func ageS(of metrics: Metrics, at now: TimeInterval) -> Double {
        let age = now - metrics.t
        return age.isFinite ? max(0, age) : .greatestFiniteMagnitude
    }
}
