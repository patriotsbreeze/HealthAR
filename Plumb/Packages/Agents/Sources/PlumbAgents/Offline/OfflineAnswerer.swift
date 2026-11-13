import Foundation
import PlumbContracts

/// Every sentence the offline "Hold to ask" can say: fixed templates, filled in from the digest.
///
/// It keeps the live voice's trust rules. Stale or lost numbers are never said, and depth is said only
/// while the lock is full. During a pause the rolling numbers describe strokes that have stopped, so
/// they are not said either. Numbers are compared with the targets as measured and said rounded; where
/// rounding would make the number and the verdict disagree, the sentence says "just under" or "just
/// over". Depth above the target gets no verdict, because the rules cannot judge "too deep" well enough
/// to coach it. Nothing here gives advice or says anything about a person.
public enum OfflineAnswerer {
    /// Said for every question while the numbers are stale or the signal is lost.
    public static let cannotSee = "I can't see the hands right now."
    /// Said for a question that is not about the compressions.
    public static let topics = "I can answer about rate, depth, pauses and count."
    /// Said when nothing was heard while the button was held.
    public static let nothingHeard = "I didn't catch that. " + topics
    /// Said for a question about the compressions before there are any.
    public static let noCompressions = "No compressions yet."

    /// The fixed answer for `intent`, from the numbers in `digest`.
    public static func answer(intent: AskIntent, digest: WorldDigest, targets: Targets = .adult) -> String {
        guard intent != .unknown else { return topics }
        guard !digest.stale, digest.lock != .lost else { return cannotSee }
        guard digest.count > 0 else { return noCompressions }
        switch intent {
        case .count:
            return digest.count == 1 ? "1 compression so far." : "\(digest.count) compressions so far."
        case .pauses:
            if digest.isPaused { return paused(digest) + "." }
            let share = SpokenNumber.percent(digest.handsOnFraction).map { " Compressing \($0) percent of the time so far." }
            return "No pause right now." + (share ?? "")
        case .rate:
            if digest.isPaused { return paused(digest) + ", so there is no rate right now." }
            return rate(digest, targets: targets, full: true)
        case .depth:
            if digest.isPaused { return paused(digest) + ", so there is no depth right now." }
            return depth(digest, targets: targets, full: true)
        case .overall:
            if digest.isPaused { return paused(digest) + "." }
            return rate(digest, targets: targets, full: false) + " " + depth(digest, targets: targets, full: false)
        case .unknown:
            return topics
        }
    }

    // MARK: - Pieces

    /// The rate against its target. `full` adds the target range, for a question about rate alone.
    private static func rate(_ digest: WorldDigest, targets: Targets, full: Bool) -> String {
        guard let measured = SpokenNumber.reading(digest.ratePerMin) else {
            return "The rate needs a few more compressions."
        }
        let said = SpokenNumber.whole(measured)
        let range = full ? " of \(SpokenNumber.whole(targets.rateMinPerMin)) to \(SpokenNumber.whole(targets.rateMaxPerMin))" : ""
        if measured < targets.rateMinPerMin {
            let number = Double(said) >= targets.rateMinPerMin ? "Just under \(said)" : "\(said)"
            return "\(number) per minute, below the target\(range)."
        }
        if measured > targets.rateMaxPerMin {
            let number = Double(said) <= targets.rateMaxPerMin ? "Just over \(said)" : "\(said)"
            return "\(number) per minute, above the target\(range)."
        }
        return "\(said) per minute, within the target\(range)."
    }

    /// The depth against its target, or why it cannot be said. `full` adds the target range.
    private static func depth(_ digest: WorldDigest, targets: Targets, full: Bool) -> String {
        switch digest.lock {
        case .locked: break
        case .estimating: return "Depth is still being estimated."
        case .rateOnly: return full ? "Depth can't be measured right now, only the rate." : "Depth can't be measured right now."
        case .lost: return cannotSee
        }
        guard let measured = SpokenNumber.reading(digest.depthMM) else { return "No depth measured yet." }
        let said = centimetres(measured)
        let range = "\(SpokenNumber.centimetres(targets.depthMinMM)) to \(SpokenNumber.centimetres(targets.depthMaxMM))"
        if measured < targets.depthMinMM {
            let number = SpokenNumber.halfCentimetreMM(measured) >= targets.depthMinMM ? "Just under \(said)" : said
            return "\(number) deep, below the target" + (full ? " of \(range)." : ".")
        }
        if measured > targets.depthMaxMM {
            return full ? "\(said) deep. The target is \(range)." : "\(said) deep."
        }
        return "\(said) deep, within the target" + (full ? " of \(range)." : ".")
    }

    /// "Paused for 5 seconds", without the full stop, so a sentence can go on from it.
    private static func paused(_ digest: WorldDigest) -> String {
        guard let seconds = SpokenNumber.seconds(digest.pauseSeconds), seconds >= 1 else { return "Paused just now" }
        return seconds == 1 ? "Paused for 1 second" : "Paused for \(seconds) seconds"
    }

    /// "5.5 centimetres", or "1 centimetre".
    private static func centimetres(_ millimetres: Double) -> String {
        let number = SpokenNumber.centimetres(millimetres)
        return number == "1" ? "1 centimetre" : "\(number) centimetres"
    }
}
