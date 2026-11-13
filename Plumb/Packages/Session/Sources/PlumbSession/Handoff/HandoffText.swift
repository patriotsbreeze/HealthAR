import Foundation
import PlumbContracts

/// The fixed wording of the handoff. Every phrase comes from the measured stats; no model is involved.
public enum HandoffText {
    /// The one-line summary, for example "CPR started 14:02. Ran 6 min 40 s. 3 pauses, longest 9 s."
    /// The start is the session start, 24-hour, in `timeZone`. With no compressions: "No compressions recorded."
    public static func headline(_ stats: HandoffStats, timeZone: TimeZone = .current) -> String {
        guard stats.compressions > 0 else { return "No compressions recorded." }
        var sentences: [String] = []
        if let started = stats.startedWallClock {
            sentences.append("CPR started \(ClockTime(started, in: timeZone).hoursAndMinutes).")
        }
        sentences.append("Ran \(duration(stats.durationS)).")
        sentences.append(pauseSentence(stats))
        return sentences.joined(separator: " ")
    }

    /// The range most trusted compressions fell in, to the nearest half centimetre, for example
    /// "4.5 to 5.5 cm". Always two different ends. Nil when depth was not recorded.
    public static func depthRange(_ stats: HandoffStats) -> String? {
        guard let band = DepthBand(stats, stepCM: SessionConfig.standard.depthStepCM) else { return nil }
        return "\(plainNumber(band.lowCM)) to \(plainNumber(band.highCM)) cm"
    }

    /// A share as a whole percentage, for example "83%", or "not recorded" when there is none.
    public static func percent(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "not recorded" }
        let whole = (min(1, max(0, fraction)) * Units.percentPerWhole).rounded()
        return "\(Int(whole))%"
    }

    /// A length of time in whole seconds, for example "6 min 40 s", "7 min" or "45 s".
    public static func duration(_ seconds: Double) -> String {
        let whole = wholeSeconds(seconds)
        let perMinute = Int(Units.secondsPerMinute)
        let minutes = whole / perMinute
        let rest = whole % perMinute
        if minutes == 0 { return "\(rest) s" }
        if rest == 0 { return "\(minutes) min" }
        return "\(minutes) min \(rest) s"
    }

    private static func pauseSentence(_ stats: HandoffStats) -> String {
        let longest = duration(stats.longestPauseS ?? stats.pauses.map(\.durationS).max() ?? 0)
        switch stats.pauses.count {
        case 0: return "No pauses."
        case 1: return "1 pause of \(longest)."
        default: return "\(stats.pauses.count) pauses, longest \(longest)."
        }
    }

    /// Seconds rounded to a whole number that is safe to print. A value that is not a number,
    /// or is below zero, counts as none.
    private static func wholeSeconds(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(exactly: seconds.rounded()) ?? .max
    }

    /// "5" for 5.0 and "5.5" for 5.5: no trailing zero that would look like extra precision.
    private static func plainNumber(_ value: Double) -> String {
        if let whole = Int(exactly: value) { return "\(whole)" }
        return "\(value)"
    }
}
