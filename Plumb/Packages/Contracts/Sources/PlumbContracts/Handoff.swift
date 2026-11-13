import Foundation

/// The measured summary handed to an arriving crew. Computed from the log and nothing else.
/// A nil field means "not recorded", and is shown as those words, never as zero.
public struct HandoffStats: Sendable, Codable, Equatable {
    public var startedWallClock: Date?
    /// Length of the session in seconds.
    public var durationS: Double
    public var timeToFirstCompressionS: Double?
    public var compressions: Int
    /// Typical rate over the session, per minute.
    public var ratePerMin: Double?
    /// Typical depth of the compressions measured while depth was trusted, in millimetres.
    public var depthMM: Double?
    /// The range most trusted compressions fell in (10th and 90th percentile), in millimetres.
    public var depthLowMM: Double?
    public var depthHighMM: Double?
    /// Share of trusted compressions that reached the target depth, 0...1.
    public var reachedTargetFraction: Double?
    /// Share of all compressions whose depth was trusted, 0...1.
    public var trustedFraction: Double?
    /// Share of the time since the first compression spent compressing, 0...1.
    public var handsOnFraction: Double?
    public var pauses: [Pause]
    public var longestPauseS: Double?
    /// The session cut into equal slices of time, oldest first, for the session bar chart.
    public var buckets: [Bucket]
    /// Plain names of things this app did not measure, for the "Not recorded" line.
    public var notRecorded: [String]

    public struct Pause: Sendable, Codable, Equatable {
        public var start: TimeInterval
        public var durationS: Double
        public init(start: TimeInterval, durationS: Double) {
            self.start = start
            self.durationS = durationS
        }
    }

    public struct Bucket: Sendable, Codable, Equatable {
        public var start: TimeInterval
        public var lengthS: Double
        public var compressions: Int
        /// Typical trusted depth in this slice, in millimetres.
        public var depthMM: Double?
        /// Seconds of this slice spent paused.
        public var pausedS: Double
        public init(start: TimeInterval, lengthS: Double, compressions: Int, depthMM: Double?, pausedS: Double) {
            self.start = start
            self.lengthS = lengthS
            self.compressions = compressions
            self.depthMM = depthMM
            self.pausedS = pausedS
        }
    }

    public init(startedWallClock: Date? = nil, durationS: Double = 0, timeToFirstCompressionS: Double? = nil,
                compressions: Int = 0, ratePerMin: Double? = nil, depthMM: Double? = nil,
                depthLowMM: Double? = nil, depthHighMM: Double? = nil, reachedTargetFraction: Double? = nil,
                trustedFraction: Double? = nil, handsOnFraction: Double? = nil, pauses: [Pause] = [],
                longestPauseS: Double? = nil, buckets: [Bucket] = [], notRecorded: [String] = []) {
        self.startedWallClock = startedWallClock
        self.durationS = durationS
        self.timeToFirstCompressionS = timeToFirstCompressionS
        self.compressions = compressions
        self.ratePerMin = ratePerMin
        self.depthMM = depthMM
        self.depthLowMM = depthLowMM
        self.depthHighMM = depthHighMM
        self.reachedTargetFraction = reachedTargetFraction
        self.trustedFraction = trustedFraction
        self.handsOnFraction = handsOnFraction
        self.pauses = pauses
        self.longestPauseS = longestPauseS
        self.buckets = buckets
        self.notRecorded = notRecorded
    }
}

/// One sentence a model wrote for the handoff, with the log entries it says back it up.
public struct ScribeSentence: Sendable, Codable, Equatable {
    public var text: String
    /// Ids of the log entries this sentence rests on.
    public var cites: [Int]
    public init(text: String, cites: [Int]) {
        self.text = text
        self.cites = cites
    }
}

/// What the fixed checker decided about one model-written sentence.
public struct ScribeVerdict: Sendable, Codable, Equatable {
    public var sentence: ScribeSentence
    public var accepted: Bool
    /// One plain sentence saying why it was refused. Nil when accepted.
    public var reason: String?
    public init(sentence: ScribeSentence, accepted: Bool, reason: String?) {
        self.sentence = sentence
        self.accepted = accepted
        self.reason = reason
    }
}

/// What a model is allowed to learn about the rescue when it asks. Every value carries its age,
/// so a model can be made to say "I can't see that right now" instead of guessing.
public struct WorldDigest: Sendable, Codable, Equatable {
    public var lock: LockState
    public var count: Int
    public var ratePerMin: Double?
    public var depthMM: Double?
    public var depthSpreadMM: Double?
    public var isPaused: Bool
    public var pauseSeconds: Double
    public var handsOnFraction: Double?
    /// Seconds since these numbers were measured.
    public var ageS: Double
    /// True when the numbers are too old or too untrusted to answer from.
    public var stale: Bool

    public init(lock: LockState, count: Int, ratePerMin: Double?, depthMM: Double?, depthSpreadMM: Double?,
                isPaused: Bool, pauseSeconds: Double, handsOnFraction: Double?, ageS: Double, stale: Bool) {
        self.lock = lock
        self.count = count
        self.ratePerMin = ratePerMin
        self.depthMM = depthMM
        self.depthSpreadMM = depthSpreadMM
        self.isPaused = isPaused
        self.pauseSeconds = pauseSeconds
        self.handsOnFraction = handsOnFraction
        self.ageS = ageS
        self.stale = stale
    }
}
