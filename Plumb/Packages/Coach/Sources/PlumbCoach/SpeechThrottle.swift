import Foundation
import PlumbContracts

/// Keeps the voice sparse: remembers what was said and when, and answers whether a correction may be said now.
///
/// Spoken prompts on every error slow people down, so the screen carries the correction and the voice only backs it up.
struct SpeechThrottle: Equatable, Sendable {
    private struct Mark: Equatable, Sendable {
        var at: TimeInterval
        var compressions: Int
    }

    /// When anything at all was last said.
    private var lastSpokeAt: TimeInterval?
    /// When each cue was last said, and the compression count at that moment.
    private var marks: [Cue: Mark] = [:]

    /// Whether "Push now" is due: the pause is long enough, and it was not said too recently in this pause.
    ///
    /// The gap that spaces out other corrections does not apply. A stopped rescuer is the most urgent thing there is.
    func allowsPushNow(pauseSeconds: Double, now: TimeInterval, config: CuePolicy.Config) -> Bool {
        guard pauseSeconds >= config.pauseSpeakAfterS else { return false }
        guard let mark = marks[.pushNow] else { return true }
        return now - mark.at >= config.pauseRepeatS
    }

    /// Whether a depth or rate correction may be said now.
    func allowsCorrective(_ cue: Cue, compressions: Int, now: TimeInterval, config: CuePolicy.Config) -> Bool {
        if let lastSpokeAt, now - lastSpokeAt < config.correctiveGapS { return false }
        guard let mark = marks[cue] else { return true }
        return now - mark.at >= config.sameCueGapS
            && compressions - mark.compressions >= config.responseCompressions
    }

    /// Notes that a cue was said on this look.
    mutating func record(_ cue: Cue, compressions: Int, now: TimeInterval) {
        lastSpokeAt = now
        marks[cue] = Mark(at: now, compressions: compressions)
    }

    /// Notes that compressions are under way, so the next pause starts its own count towards "Push now".
    mutating func pauseEnded() {
        marks[.pushNow] = nil
    }
}
