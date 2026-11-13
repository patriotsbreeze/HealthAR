import Foundation
import PlumbContracts

/// What the scribe produced for one handoff, with its working shown.
public struct ScribeResult: Sendable, Equatable {
    /// Sentences that passed the check, in the order they should be read. Never contains a refused one.
    public var accepted: [ScribeSentence]
    /// Every verdict from both rounds, first round first, for the "show working" view.
    public var verdicts: [ScribeVerdict]
    /// How many requests were made to the model: 0, 1 or 2.
    public var requests: Int
    /// Wall-clock time the whole attempt took, in seconds.
    public var seconds: Double
    /// One plain sentence when a request failed. `accepted` then holds only what had already
    /// passed the check, which is nothing when the first request was the one that failed.
    public var failure: String?

    /// Creates a result. The defaults describe an attempt that produced nothing.
    public init(accepted: [ScribeSentence] = [], verdicts: [ScribeVerdict] = [], requests: Int = 0,
                seconds: Double = 0, failure: String? = nil) {
        self.accepted = accepted
        self.verdicts = verdicts
        self.requests = requests
        self.seconds = seconds
        self.failure = failure
    }
}
