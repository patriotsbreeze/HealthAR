import PlumbContracts

/// Keeps track of who is speaking and until when, measured in beat samples.
///
/// The beat's sample counter is the only clock, so "is a cue still playing" has one answer on
/// every thread and needs no callback from the audio system.
struct SpeechTimeline: Sendable, Equatable {
    /// Samples added after a cue or model speech should have ended, to cover a player's start delay.
    let tailFrames: Int64

    private var cue: Cue?
    private var cueEnd: Int64 = 0
    private var modelEnd: Int64 = 0
    /// The beat stays ducked for every sample before this one.
    private(set) var duckEnd: Int64 = 0

    init(tailFrames: Int64) {
        self.tailFrames = tailFrames
    }

    /// Whether a cue is still being spoken at sample `now`.
    func cuePlaying(at now: Int64) -> Bool {
        cue != nil && now < cueEnd
    }

    /// Whether a new cue may start at sample `now`. Only "push now" may cut in on another cue,
    /// and a cue never cuts in on itself: a phrase that restarted every time it was asked for
    /// again would never finish.
    func admits(_ newCue: Cue, at now: Int64) -> Bool {
        guard let playing = cue, now < cueEnd else { return true }
        return newCue == .pushNow && playing != .pushNow
    }

    /// Records that a cue of `frames` samples started at `now`, cutting off any model speech.
    mutating func cueStarted(_ newCue: Cue, at now: Int64, frames: Int64) {
        cue = newCue
        cueEnd = now + frames + tailFrames
        modelEnd = now
        duckEnd = cueEnd
    }

    /// Records that `frames` more samples of model speech were queued behind what is already waiting.
    mutating func modelQueued(at now: Int64, frames: Int64) {
        modelEnd = max(now, modelEnd) + frames
        duckEnd = max(duckEnd, modelEnd + tailFrames)
    }

    /// Records that model speech was cut off at `now`.
    mutating func modelStopped(at now: Int64) {
        guard modelEnd > now else { return }
        modelEnd = now
        duckEnd = max(cueEnd, now)
    }
}
