import Foundation
import RescueVision

/// The form score and the spoken corrections during compressions, from the same pose feedback that
/// draws the band's coaching line. It never scores depth, and it says nothing about anything it
/// can't see: a missing reading counts neither for nor against the score.
struct FormCoach {
    /// The steps where pushing is the job, so the deck is the form and the rest folds into Next step.
    static let pushingStates: Set<String> = ["compressions", "compressions_aed"]
    /// The score covers this much of the latest pushing.
    static let window: TimeInterval = 30
    /// Less seen than this and there's no score to show yet.
    static let minSeen: TimeInterval = 3
    /// A correction has to hold this long before it's said, as it does before the band shows it.
    static let cueHold: TimeInterval = 0.8
    /// The least time between two spoken corrections, so it coaches without nagging.
    static let spokenGap: TimeInterval = 4
    /// The same correction again only after this long, if it still holds.
    static let repeatGap: TimeInterval = 8

    struct Reading: Equatable {
        /// 0 to 100, or nil until enough has been seen.
        var score: Int?
        var perMinute: Int?
        var cue: CompressionFeedback.Cue?
    }

    private var samples: [(at: TimeInterval, good: Bool)] = []
    private var candidate: (cue: CompressionFeedback.Cue?, since: TimeInterval)?
    private var heldCue: CompressionFeedback.Cue?
    private var lastSpoken: (cue: CompressionFeedback.Cue, at: TimeInterval)?

    mutating func reset() { self = FormCoach() }

    /// Takes this tick's feedback and returns what to show, and the correction to say, if any.
    /// - Parameter canSpeak: false while the app or the AI is talking, so a correction never cuts a step.
    mutating func update(_ feedback: CompressionFeedback?, at now: TimeInterval, canSpeak: Bool) -> (reading: Reading, say: CompressionFeedback.Cue?) {
        samples.removeAll { now - $0.at > Self.window }
        // Only a reading with a rate in it is a push seen, so the score is of pushing, not of kneeling.
        if let feedback, feedback.perMinute != nil {
            samples.append((now, feedback.cue == nil))
        }

        let cue = feedback?.cue
        if candidate?.cue != cue { candidate = (cue, now) }
        if let candidate, now - candidate.since >= Self.cueHold { heldCue = candidate.cue }

        var say: CompressionFeedback.Cue?
        if let heldCue, canSpeak, now - (lastSpoken?.at ?? -.infinity) >= Self.spokenGap,
           lastSpoken?.cue != heldCue || now - lastSpoken!.at >= Self.repeatGap {
            say = heldCue
            lastSpoken = (heldCue, now)
        }

        return (Reading(score: score, perMinute: feedback?.perMinute.map { Int($0.rounded()) }, cue: heldCue), say)
    }

    /// Samples arrive once a tick, so their count stands in for time.
    private var score: Int? {
        guard let first = samples.first, let last = samples.last, last.at - first.at >= Self.minSeen else { return nil }
        let good = samples.filter(\.good).count
        return Int((Double(good) / Double(samples.count) * 100).rounded())
    }

    static func phraseID(for cue: CompressionFeedback.Cue) -> String {
        switch cue {
        case .handsToCenter: "form_hands_center"
        case .lockElbows: "form_lock_elbows"
        case .pushFaster: "rate_faster"
        case .pushSlower: "rate_slower"
        case .followBeat: "form_follow_beat"
        }
    }
}
