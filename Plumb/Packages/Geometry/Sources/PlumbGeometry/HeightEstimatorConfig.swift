import Foundation

extension HeightEstimator {
    /// Every tunable number of the height estimators, with the defaults they ship with.
    public struct Config: Sendable, Equatable {
        /// Lowest LiDAR confidence a depth sample needs to be used (0 low, 1 medium, 2 high). Default 1.
        public var minConfidence: UInt8
        /// How a surface is picked out of a depth patch.
        public var surface: DepthPatch.SurfaceConfig
        /// How the picture shift is searched for.
        public var shift: ShiftEstimator.Config

        /// Share of the hands patch the hands should fill for full trust; less scales quality
        /// down in proportion. Default 0.3.
        public var fullFillFraction: Double
        /// Depth spread of the hands (interquartile range) up to which nothing is taken off;
        /// beyond it quality falls as calm / spread. Default 0.04 m.
        public var calmSpreadM: Double
        /// Highest quality reported while world tracking is not normal. Default 0.3.
        public var notTrackingCap: Double
        /// What quality is multiplied by when the along-ray method has no still reference to
        /// check the camera against. Default 0.9.
        public var noReferenceFactor: Double

        /// Seconds of the reference's height kept: its median is the reference's level and its
        /// standard deviation is the reported noise. Default 2.
        public var referenceWindowS: TimeInterval
        /// Reference readings needed inside the window before its level is believed. Default 10.
        public var referenceMinReadings: Int
        /// A change of the reference's level larger than this from one frame to the next is taken
        /// to be a different reference, not the camera drifting, and is not passed on. Default 15 mm.
        public var referenceJumpMM: Double
        /// Fastest the drift correction may change. Real drift is far slower, so anything quicker
        /// is eased in at this rate and never steps the heights. Default 5 mm a second.
        public var referenceMaxDriftMMPerS: Double
        /// Share of the reference's frame-to-frame deviation from its own level that is also taken
        /// off the hands' height. 0 follows only slow drift and adds no noise; 1 also cancels
        /// shake the two patches share, at the price of adding the reference's own noise. Default 0.
        public var referenceFastShare: Double

        /// Seconds of the hands' floor-plan position whose median is the ruler that turns pixels
        /// into millimetres and gives the reported distance. Default 1.
        public var rulerWindowS: TimeInterval
        /// Picture match below which the image-plane method takes a new key frame. Default 0.5.
        public var rekeyCorrelation: Double
        /// Highest quality reported on a frame that forced a new key frame. Default 0.1.
        public var rekeyQuality: Double

        /// Builds a config; every argument defaults to the documented value.
        public init(minConfidence: UInt8 = 1, surface: DepthPatch.SurfaceConfig = .init(),
                    shift: ShiftEstimator.Config = .init(), fullFillFraction: Double = 0.3,
                    calmSpreadM: Double = 0.04, notTrackingCap: Double = 0.3, noReferenceFactor: Double = 0.9,
                    referenceWindowS: TimeInterval = 2, referenceMinReadings: Int = 10,
                    referenceJumpMM: Double = 15, referenceMaxDriftMMPerS: Double = 5,
                    referenceFastShare: Double = 0,
                    rulerWindowS: TimeInterval = 1, rekeyCorrelation: Double = 0.5, rekeyQuality: Double = 0.1) {
            self.minConfidence = minConfidence
            self.surface = surface
            self.shift = shift
            self.fullFillFraction = fullFillFraction
            self.calmSpreadM = calmSpreadM
            self.notTrackingCap = notTrackingCap
            self.noReferenceFactor = noReferenceFactor
            self.referenceWindowS = referenceWindowS
            self.referenceMinReadings = referenceMinReadings
            self.referenceJumpMM = referenceJumpMM
            self.referenceMaxDriftMMPerS = referenceMaxDriftMMPerS
            self.referenceFastShare = referenceFastShare
            self.rulerWindowS = rulerWindowS
            self.rekeyCorrelation = rekeyCorrelation
            self.rekeyQuality = rekeyQuality
        }
    }
}
