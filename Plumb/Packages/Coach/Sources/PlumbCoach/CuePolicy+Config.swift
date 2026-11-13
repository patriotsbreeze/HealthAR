import Foundation

extension CuePolicy {
    /// Every number the rules can be tuned with. The defaults are the ones the rules were designed around.
    public struct Config: Sendable, Equatable {
        // MARK: Pauses

        /// Seconds a pause must have lasted before "Push now" is said. Default 3.
        public var pauseSpeakAfterS: TimeInterval = 3
        /// Seconds between repeats of "Push now" while the same pause goes on. Default 5.
        public var pauseRepeatS: TimeInterval = 5
        /// Seconds the signal must have been back after a loss before a pause is believed. Default 1.
        public var signalSettleS: TimeInterval = 1

        // MARK: Faults

        /// Millimetres typical depth must fall short of the target minimum to count as shallow,
        /// and must exceed it by to count as fixed. Default 3.
        public var depthDeadBandMM: Double = 3
        /// Compressions per minute the rate must be outside the target range to count as a fault,
        /// and must be back inside it by to count as fixed. Default 3.
        public var rateDeadBandPerMin: Double = 3
        /// Seconds a fault must last before it is shown. A sighting not repeated within this time is forgotten,
        /// and a run of good work survives being unable to judge for this long. Default 2.5.
        public var persistS: TimeInterval = 2.5
        /// Compressions needed since the session start or the last pause before rate is judged. Default 6.
        public var minCompressionsForRate: Int = 6

        // MARK: Speech

        /// Seconds of silence required after anything is said before a correction may be said. Default 6.
        public var correctiveGapS: TimeInterval = 6
        /// Seconds before the same correction may be said again. Default 12.
        public var sameCueGapS: TimeInterval = 12
        /// New compressions required after a spoken correction before it may be said again,
        /// so the person has a chance to respond. Default 4.
        public var responseCompressions: Int = 4

        // MARK: Praise

        /// Compressions that must be on target after a correction was shown before "good" is given. Default 4.
        public var recoveryCompressions: Int = 4
        /// Seconds "good" stays on screen once given. Default 2.
        public var praiseShowS: TimeInterval = 2
        /// Seconds of unbroken on-target work between unprompted "good"s. Default 30.
        public var steadyPraiseEveryS: TimeInterval = 30

        /// Makes a config with every value at its default.
        public init() {}
    }
}
