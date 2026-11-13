import Foundation

/// One stretch of a made-up session: someone compressing at a steady rate and depth, or holding still.
public struct SyntheticSegment: Sendable, Equatable {
    public var duration: TimeInterval
    /// Compressions per minute. 0 means the hands are still.
    public var ratePerMin: Double
    public var depthMM: Double

    public init(duration: TimeInterval, ratePerMin: Double, depthMM: Double) {
        self.duration = duration
        self.ratePerMin = ratePerMin
        self.depthMM = depthMM
    }

    public static func pause(_ duration: TimeInterval) -> SyntheticSegment {
        SyntheticSegment(duration: duration, ratePerMin: 0, depthMM: 0)
    }
}

/// Deterministic fake hand-height signals with known ground truth.
/// Used by tests, by previews, and by the app's replay mode. Never presented as a real measurement.
public enum SyntheticSession {
    /// Fraction of each cycle spent going down, then coming up. The rest is spent resting at the top.
    public static let downFraction = 0.35
    public static let upFraction = 0.35

    /// Shape of one stroke. `phase` runs 0..<1 over a cycle; the result is 0 at the top and 1 at the bottom.
    public static func strokeShape(phase: Double) -> Double {
        let p = phase - phase.rounded(.down)
        if p < downFraction {
            return (1 - cos(.pi * p / downFraction)) / 2
        }
        if p < downFraction + upFraction {
            return (1 + cos(.pi * (p - downFraction) / upFraction)) / 2
        }
        return 0
    }

    /// What really happened in a made-up session.
    public struct Truth: Sendable, Equatable {
        public var bottoms: [Bottom]
        /// Stretches with no compressions, as (start, end) in seconds.
        public var stillSpans: [ClosedRange<TimeInterval>]

        public struct Bottom: Sendable, Equatable {
            public var t: TimeInterval
            public var depthMM: Double
        }
    }

    public static func truth(_ segments: [SyntheticSegment], startT: TimeInterval = 0) -> Truth {
        var bottoms: [Truth.Bottom] = []
        var still: [ClosedRange<TimeInterval>] = []
        var t0 = startT
        for segment in segments {
            if segment.ratePerMin > 0, segment.depthMM > 0 {
                let period = 60 / segment.ratePerMin
                var k = 0
                while true {
                    let t = (Double(k) + downFraction) * period
                    if t >= segment.duration { break }
                    bottoms.append(.init(t: t0 + t, depthMM: segment.depthMM))
                    k += 1
                }
            } else if segment.duration > 0 {
                still.append(t0...(t0 + segment.duration))
            }
            t0 += segment.duration
        }
        return Truth(bottoms: bottoms, stillSpans: still)
    }

    /// Samples for a made-up session. Each segment starts at the top of a stroke.
    ///
    /// - Parameters:
    ///   - noiseMM: standard deviation of the measurement noise added to every sample.
    ///   - driftMMPerMin: slow steady drift of the baseline, as a real camera would show.
    ///   - dropEvery: when above 0, every nth sample is left out, as a dropped frame would be.
    public static func samples(_ segments: [SyntheticSegment], sampleHz: Double = 60,
                               noiseMM: Double = 1.5, driftMMPerMin: Double = 0, quality: Double = 1,
                               dropEvery: Int = 0, seed: UInt64 = 1,
                               startT: TimeInterval = 0) -> [HeightSample] {
        precondition(sampleHz > 0)
        var rng = SplitMix64(seed: seed)
        var out: [HeightSample] = []
        let dt = 1 / sampleHz
        var segmentStart = startT
        var n = 0
        for segment in segments {
            let steps = Int((segment.duration * sampleHz).rounded(.down))
            for i in 0..<steps {
                let local = Double(i) * dt
                let t = segmentStart + local
                var h = 0.0
                if segment.ratePerMin > 0 {
                    h = -segment.depthMM * strokeShape(phase: local * segment.ratePerMin / 60)
                }
                h += driftMMPerMin * (t - startT) / 60
                h += noiseMM * rng.nextGaussian()
                n += 1
                if dropEvery > 0, n % dropEvery == 0 { continue }
                out.append(HeightSample(t: t, heightMM: h, quality: quality))
            }
            segmentStart += segment.duration
        }
        return out
    }

    /// A short session that tells a story: too shallow, corrected, a pause, then good.
    public static let demo: [SyntheticSegment] = [
        .pause(1.5),
        SyntheticSegment(duration: 9, ratePerMin: 104, depthMM: 38),
        SyntheticSegment(duration: 10, ratePerMin: 110, depthMM: 54),
        .pause(5),
        SyntheticSegment(duration: 12, ratePerMin: 112, depthMM: 55),
    ]
}

/// Small seeded generator so made-up sessions are the same on every run and every machine.
public struct SplitMix64: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// Roughly normal, mean 0, standard deviation 1.
    public mutating func nextGaussian() -> Double {
        var sum = 0.0
        for _ in 0..<12 { sum += nextUnit() }
        return sum - 6
    }
}
