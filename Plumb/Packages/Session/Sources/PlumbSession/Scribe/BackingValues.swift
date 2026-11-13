import Foundation
import PlumbContracts

/// The values one sentence is allowed to state: the session's handoff numbers, plus the facts
/// held by the log entries the sentence cites. Nothing else can back a number.
struct BackingValues {
    var compressionCount: Int
    var pauseCount: Int
    var depthsMM: [Double] = []
    var ratesPerMin: [Double] = []
    /// Lengths of time and moments in the session, in seconds.
    var seconds: [Double] = []
    var percents: [Double] = []
    var sessionStarts: [Date] = []

    init(stats: HandoffStats, cited: [LogEntry], config: SessionConfig) {
        compressionCount = stats.compressions
        pauseCount = stats.pauses.count
        add(stats, config: config)

        var citedStrokes: [Compression] = []
        for entry in cited {
            if case .compression(let stroke) = entry.body {
                citedStrokes.append(stroke)
            } else {
                add(entry)
            }
        }
        add(citedStrokes, config: config)
    }

    /// The allowed values for one kind of claim, in the unit the claim is written in.
    func candidates(for kind: NumberClaim.Kind) -> [Double] {
        switch kind {
        case .count(.compressions): return [Double(compressionCount)]
        case .count(.pauses): return [Double(pauseCount)]
        case .count(nil): return [Double(compressionCount), Double(pauseCount)]
        case .depthMM: return depthsMM
        case .depthCM: return depthsMM.map { $0 / Units.mmPerCM }
        case .rate: return ratesPerMin
        case .seconds: return seconds
        case .minutes: return seconds.map { $0 / Units.secondsPerMinute }
        case .percent: return percents
        }
    }

    private mutating func add(_ stats: HandoffStats, config: SessionConfig) {
        depthsMM += [stats.depthMM, stats.depthLowMM, stats.depthHighMM].compactMap { $0 }
        // The handoff shows depth as a rounded range, so a sentence may repeat the range as shown.
        if let band = DepthBand(stats, stepCM: config.depthStepCM) {
            depthsMM += [band.lowCM * Units.mmPerCM, band.highCM * Units.mmPerCM]
        }
        ratesPerMin += [stats.ratePerMin].compactMap { $0 }
        seconds += [stats.durationS, stats.timeToFirstCompressionS, stats.longestPauseS].compactMap { $0 }
        seconds += stats.pauses.flatMap { [$0.start, $0.durationS] }
        percents += [stats.reachedTargetFraction, stats.trustedFraction, stats.handsOnFraction]
            .compactMap { $0 }
            .map { $0 * Units.percentPerWhole }
        sessionStarts += [stats.startedWallClock].compactMap { $0 }
    }

    /// What one cited entry that is not a compression backs: when it happened, and for a pause
    /// its start, end and length.
    private mutating func add(_ entry: LogEntry) {
        seconds.append(entry.t)
        switch entry.body {
        case .sessionStarted(let wallClock):
            sessionStarts.append(wallClock)
        case .pause(let start, let end):
            seconds += [start, end, end - start]
        case .compression, .sessionEnded, .lock, .cue, .toolCall, .blocked, .found, .note:
            break
        }
    }

    /// What the cited compressions back, taken as a group: their typical trusted depth, their
    /// typical rate, and when the first and last of them happened.
    ///
    /// Compressions come about two a second. If each cited one backed its own time and depth, a
    /// sentence citing a whole run could state almost any number of seconds or millimetres and
    /// find a compression to match. A depth measured while depth was not trusted backs nothing.
    private mutating func add(_ strokes: [Compression], config: SessionConfig) {
        depthsMM += [Quantiles.median(strokes.trustedDepthsMM)].compactMap { $0 }
        ratesPerMin += [strokes.typicalRatePerMin(minIntervals: config.citedRateMinIntervals)].compactMap { $0 }
        let bottoms = strokes.map(\.tBottom)
        seconds += [bottoms.min(), bottoms.max()].compactMap { $0 }
    }
}
