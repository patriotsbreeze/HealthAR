import Foundation
import PlumbContracts

/// Deterministic made-up chest heights with known truth.
/// Used by tests, by previews, and by the app's replay mode. Never presented as a real measurement.
public enum SyntheticChest {
    /// One stretch: the chest rising and falling evenly, or held still where the stretch before left it.
    public struct Segment: Sendable, Equatable {
        public var duration: TimeInterval
        /// Rises and falls per second. 0 means still.
        public var frequencyHz: Double
        /// Half the distance from lowest to highest, in millimetres.
        public var amplitudeMM: Double

        /// A stretch of the given length, frequency and amplitude.
        public init(duration: TimeInterval, frequencyHz: Double, amplitudeMM: Double) {
            self.duration = duration
            self.frequencyHz = frequencyHz
            self.amplitudeMM = amplitudeMM
        }

        /// The chest rising and falling, by default fifteen times a minute and 4 mm either way.
        public static func moving(_ duration: TimeInterval, frequencyHz: Double = 0.25,
                                  amplitudeMM: Double = 4) -> Segment {
            Segment(duration: duration, frequencyHz: frequencyHz, amplitudeMM: amplitudeMM)
        }

        /// The chest held still.
        public static func still(_ duration: TimeInterval) -> Segment {
            Segment(duration: duration, frequencyHz: 0, amplitudeMM: 0)
        }
    }

    /// The demo: twenty seconds of the chest rising and falling, then twenty-five seconds held still.
    public static let demo: [Segment] = [.moving(20), .still(25)]

    /// Samples for a made-up session. Each moving stretch starts at the height the one before ended on.
    ///
    /// - Parameters:
    ///   - noiseMM: standard deviation of the measurement noise added to every sample.
    ///   - driftMMPerMin: slow steady drift of the measurement, as a real sensor may show.
    public static func samples(_ segments: [Segment], sampleHz: Double = 60, noiseMM: Double = 0.8,
                               driftMMPerMin: Double = 0, quality: Double = 1, seed: UInt64 = 1,
                               startT: TimeInterval = 0) -> [HeightSample] {
        precondition(sampleHz > 0)
        var rng = SplitMix64(seed: seed)
        var out: [HeightSample] = []
        var segmentStart = startT
        var levelMM = 0.0
        for segment in segments {
            let steps = Int((segment.duration * sampleHz).rounded(.down))
            for index in 0..<steps {
                let local = Double(index) / sampleHz
                let t = segmentStart + local
                let height = levelMM + height(of: segment, at: local) + driftMMPerMin * (t - startT) / 60
                out.append(HeightSample(t: t, heightMM: height + noiseMM * rng.nextGaussian(), quality: quality))
            }
            levelMM += height(of: segment, at: segment.duration)
            segmentStart += segment.duration
        }
        return out
    }

    /// Height above where the stretch began, `local` seconds into it.
    private static func height(of segment: Segment, at local: TimeInterval) -> Double {
        segment.amplitudeMM * sin(2 * .pi * segment.frequencyHz * local)
    }
}
