import Foundation
import PlumbContracts

/// Computes the measured handoff from the session log and nothing else.
public enum HandoffCalculator {
    /// The handoff numbers for a session that ran from 0 to `endT` seconds, with chart slices `bucketS` wide.
    /// Depth uses only compressions measured while depth was trusted; a field with nothing behind it is nil.
    public static func stats(log: [LogEntry], endT: TimeInterval, targets: Targets = .adult,
                             bucketS: Double = SessionConfig.standard.bucketS) -> HandoffStats {
        var config = SessionConfig.standard
        config.bucketS = bucketS
        return stats(log: log, endT: endT, targets: targets, config: config)
    }

    static func stats(log: [LogEntry], endT: TimeInterval, targets: Targets,
                      config: SessionConfig) -> HandoffStats {
        let facts = LogFacts(log)
        let duration = endT.isFinite ? max(0, endT) : 0
        let pauses = facts.pauses(within: duration)
        let depths = facts.compressions.trustedDepthsMM
        let firstCompressionT = facts.compressions.first?.tBottom
        let rate = facts.compressions.typicalRatePerMin(minIntervals: config.sessionRateMinIntervals)

        return HandoffStats(
            startedWallClock: facts.startedWallClock,
            durationS: duration,
            timeToFirstCompressionS: firstCompressionT,
            compressions: facts.compressions.count,
            ratePerMin: rate,
            depthMM: Quantiles.median(depths),
            depthLowMM: Quantiles.quantile(depths, config.depthLowQuantile),
            depthHighMM: Quantiles.quantile(depths, config.depthHighQuantile),
            reachedTargetFraction: share(depths.filter { $0 >= targets.depthMinMM }.count, of: depths.count),
            trustedFraction: share(depths.count, of: facts.compressions.count),
            handsOnFraction: handsOnFraction(since: firstCompressionT, until: duration,
                                             pausedS: pauses.reduce(0) { $0 + $1.durationS }),
            pauses: pauses,
            longestPauseS: pauses.map(\.durationS).max(),
            buckets: HandoffBuckets.make(compressions: facts.compressions, pauses: pauses, endT: duration,
                                         config: config),
            notRecorded: NotRecorded.names(hasTrustedDepth: !depths.isEmpty, hasRate: rate != nil))
    }

    /// `part` over `whole`, or nil when there is no whole to take a share of.
    private static func share(_ part: Int, of whole: Int) -> Double? {
        whole > 0 ? Double(part) / Double(whole) : nil
    }

    /// Share of the time since the first compression that was not a pause. Nil when there was no
    /// compression, or no time after the first one to take a share of.
    private static func handsOnFraction(since first: TimeInterval?, until endT: TimeInterval,
                                        pausedS: Double) -> Double? {
        guard let first, endT > first else { return nil }
        return min(1, max(0, 1 - pausedS / (endT - first)))
    }
}

/// The plain names on the handoff's "Not recorded" line.
enum NotRecorded {
    /// Things this app has no way to know, whatever happened in the session.
    static let never = ["collapse time", "breathing", "shocks", "medicines"]
    static let depth = "depth"
    static let rate = "rate"

    static func names(hasTrustedDepth: Bool, hasRate: Bool) -> [String] {
        never + (hasTrustedDepth ? [] : [depth]) + (hasRate ? [] : [rate])
    }
}
