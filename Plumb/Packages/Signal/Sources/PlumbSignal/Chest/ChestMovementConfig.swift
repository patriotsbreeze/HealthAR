import Foundation

extension ChestMovementAnalyzer {
    /// Every number that shapes the chest check, in one place.
    /// The defaults suit a phone about a metre from someone lying on a mat, delivering 30 to 60 samples a second.
    public struct Config: Sendable {
        // MARK: Which samples count

        /// A sample below this quality is not used. Too many in a row and the chest counts as unmeasured.
        public var minQuality: Double = 0.3

        /// Seconds without a usable sample before the chest counts as unmeasured.
        /// Watching then starts afresh with the next usable sample, so time not seen is never counted as quiet.
        public var lostAfterS: Double = 1.0

        // MARK: Cleaning the signal

        /// Samples are gathered into bins this many seconds long, and each bin stands for its median.
        /// A lone spike cannot move a median, so it cannot pass as movement.
        public var binS: Double = 0.1

        /// Time constant, in seconds, of the smoothing applied to the bins.
        /// It keeps the slow rise and fall of a chest and drops jitter above about 0.8 Hz.
        public var smoothingTimeS: Double = 0.2

        // MARK: What counts as movement

        /// Seconds of the sliding window. Movement is a rise or fall of at least the threshold inside it.
        /// Anything slower than this cannot make one, so a slow drift of the measurement is never movement.
        public var windowS: Double = 8

        /// The threshold is never smaller than this many millimetres, however steady the measurement.
        public var minSwingMM: Double = 2

        /// The threshold is at least this many times the noise floor the caller reports.
        public var noiseMultiple: Double = 3

        // MARK: Timing

        /// Seconds of watching before movement is reported, so a glimpse is not taken as a reading.
        public var settleS: Double = 3

        /// Seconds the chest must stay inside the threshold before no movement is reported and the prompt fires.
        public var noMovementAfterS: Double = 10

        /// Seconds of trace kept for drawing.
        public var traceS: Double = 30

        /// The documented defaults.
        public init() {}
    }
}
