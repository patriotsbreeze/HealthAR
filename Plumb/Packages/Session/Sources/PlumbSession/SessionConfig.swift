import Foundation

/// Every tunable number in the session package, in one place, with the value the app ships with.
public struct SessionConfig: Sendable, Equatable {
    /// Width of one slice of the session bar chart, in seconds.
    public var bucketS: Double
    /// Most slices the chart is ever cut into. A very long session gets wider slices, not more of them.
    public var maxBuckets: Int
    /// A final slice shorter than this share of a full one is rounding noise and is left out.
    public var sliverShare: Double
    /// Where the low end of the reported depth range sits among trusted depths, from 0 to 1.
    public var depthLowQuantile: Double
    /// Where the high end of the reported depth range sits among trusted depths, from 0 to 1.
    public var depthHighQuantile: Double
    /// Step the displayed depth range is rounded to, in centimetres.
    public var depthStepCM: Double
    /// Fewest gaps between compressions before the session has a rate at all.
    public var sessionRateMinIntervals: Int
    /// Fewest gaps among the compressions a sentence cites before it may state their own rate.
    /// One gap is a single stroke, not a rate.
    public var citedRateMinIntervals: Int
    /// Age in seconds after which live numbers are too old for a model to answer from.
    public var staleAfterS: Double
    /// Most model-written sentences kept for one handoff.
    public var maxSentences: Int
    /// Most words one model-written sentence may have.
    public var maxWords: Int
    /// A banned stem this short or shorter must be the whole word, so "mg" or "of" never match inside longer words.
    public var wholeWordStemLength: Int
    /// How many words after a number are searched for the thing it counts, as in "3 long pauses".
    public var countNounReach: Int
    /// Slack on top of half a unit of the last written digit when a written number is compared
    /// with a recorded one. It covers floating-point noise only.
    public var roundingSlack: Double

    /// Builds a configuration. Every argument defaults to the shipped value.
    public init(bucketS: Double = 10, maxBuckets: Int = 720, sliverShare: Double = 1e-9,
                depthLowQuantile: Double = 0.10, depthHighQuantile: Double = 0.90, depthStepCM: Double = 0.5,
                sessionRateMinIntervals: Int = 1, citedRateMinIntervals: Int = 2, staleAfterS: Double = 2,
                maxSentences: Int = 3, maxWords: Int = 30, wholeWordStemLength: Int = 3,
                countNounReach: Int = 2, roundingSlack: Double = 1e-6) {
        self.bucketS = bucketS
        self.maxBuckets = maxBuckets
        self.sliverShare = sliverShare
        self.depthLowQuantile = depthLowQuantile
        self.depthHighQuantile = depthHighQuantile
        self.depthStepCM = depthStepCM
        self.sessionRateMinIntervals = sessionRateMinIntervals
        self.citedRateMinIntervals = citedRateMinIntervals
        self.staleAfterS = staleAfterS
        self.maxSentences = maxSentences
        self.maxWords = maxWords
        self.wholeWordStemLength = wholeWordStemLength
        self.countNounReach = countNounReach
        self.roundingSlack = roundingSlack
    }

    /// The values the app ships with.
    public static let standard = SessionConfig()
}
