import Foundation

extension CompressionAnalyzer {
    /// Every number that shapes how the analyzer behaves, in one place.
    /// The defaults suit a phone about a metre from the rescuer, delivering 30 to 60 samples a second.
    public struct Config: Sendable {
        // MARK: Cleaning the signal

        /// Time constant, in seconds, of the light smoothing used to find strokes.
        /// Depth itself is measured from the unsmoothed samples, so this never shrinks it.
        public var smoothingTimeS: Double = 0.03

        /// A sample that jumps more than this many millimetres from the one before is held back
        /// until the next sample shows whether it was a one-sample spike.
        public var spikeJumpMM: Double = 30

        /// Fastest a hand can believably move, in millimetres per second. A lasting jump faster
        /// than this is taken as the height reference shifting, and is cancelled out.
        public var maxHandSpeedMMPerS: Double = 1500

        // MARK: Finding strokes

        /// How far, in millimetres, the hands must drop below the top before a stroke is considered begun.
        public var strokeStartDropMM: Double = 8

        /// How far, in millimetres, the hands must come back up from the lowest point before it is taken as the deepest point.
        public var bottomConfirmRiseMM: Double = 6

        /// How fast, in millimetres per second, the tracked top sinks when the hands stay below it.
        /// Fast enough to follow drift and slow swaying, far too slow to follow a compression.
        public var topDroopMMPerS: Double = 25

        /// Samples within this many millimetres of the highest point before a stroke count as "resting at the top".
        public var topBandMM: Double = 4

        /// Half-width, in seconds, of the stretch around the deepest point used to measure it.
        public var bottomFitHalfWindowS: Double = 0.07

        /// How many seconds of recent samples are kept for measuring the top and bottom of a stroke.
        public var historyS: Double = 0.6

        /// The most samples kept in that history. At very high sample rates the history covers less time.
        public var historyCapacity: Int = 128

        /// How long, in seconds, the top of the last stroke keeps anchoring the live depth bar after its deepest point.
        public var topHoldS: Double = 1.0

        // MARK: What counts as a compression

        /// Shallowest stroke that counts, as a share of the minimum target depth (0.3 of 50 mm is 15 mm).
        public var minDepthFraction: Double = 0.3

        /// Deepest stroke that counts, as a multiple of the maximum target depth (2 times 60 mm is 120 mm).
        public var maxDepthFactor: Double = 2.0

        /// A stroke must also stay down: the average height around its deepest point has to be at least
        /// this share of the shallowest counted depth below the top. Rejects dips that noise alone can make.
        public var minHeldDepthShare: Double = 0.6

        /// Shortest believable time, in seconds, from leaving the top to the deepest point.
        public var minDescentS: Double = 0.07

        /// Longest believable time, in seconds, from leaving the top to the deepest point.
        /// A drop that has not turned back within this long is given up as swaying or settling.
        public var maxDescentS: Double = 0.5

        /// Refractory time: the least time, in seconds, between two deepest points (0.25 s is 240 a minute).
        public var refractoryS: Double = 0.25

        // MARK: Rolling numbers

        /// How many of the latest intervals the rate is taken from.
        public var rateWindow: Int = 6

        /// How many of the latest compressions the typical depth is taken from.
        public var depthWindow: Int = 5

        /// Seconds without a compression before it counts as a pause.
        public var pauseAfterS: Double = 2.0

        // MARK: Trust

        /// Sample quality at or above this gives full trust (locked).
        public var lockedQuality: Double = 0.6

        /// Sample quality at or above this, but below `lockedQuality`, gives partial trust (estimating).
        public var estimatingQuality: Double = 0.3

        /// Seconds of good quality it takes for trust to go up. Poor quality in between sets it back.
        public var trustGainS: Double = 1.0

        /// Seconds of poor quality it takes for trust to go down. Shorter than `trustGainS`, so doubt wins quickly.
        public var trustLossS: Double = 0.3

        /// Seconds without any sample before the signal counts as lost.
        public var lostAfterS: Double = 0.5

        /// The documented defaults.
        public init() {}
    }
}
