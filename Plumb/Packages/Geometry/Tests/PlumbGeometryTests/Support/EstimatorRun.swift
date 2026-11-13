import Foundation
import PlumbContracts
@testable import PlumbGeometry

/// Made-up sessions with known hand heights, as millimetres above the hands' rest position.
enum Session {
    static let strokeDepthMM = 50.0

    /// Half a second of stillness, steady strokes of 50 mm at 110 a minute, half a second of stillness.
    static func strokes(seconds: Double = 6) -> [HeightSample] {
        SyntheticSession.samples(
            [.pause(0.5), SyntheticSegment(duration: seconds, ratePerMin: 110, depthMM: strokeDepthMM), .pause(0.5)],
            sampleHz: 60, noiseMM: 0)
    }

    /// Hands held still.
    static func still(seconds: Double) -> [HeightSample] {
        SyntheticSession.samples([.pause(seconds)], sampleHz: 60, noiseMM: 0)
    }

    /// Hands still, then lifted smoothly by `riseMM` over half a second, then still again.
    static func lift(byMM riseMM: Double) -> [HeightSample] {
        (0..<90).map { index in
            let t = Double(index) / 60
            let progress = min(max((t - 0.5) / 0.5, 0), 1)
            return HeightSample(t: t, heightMM: riseMM * progress)
        }
    }
}

/// What an estimator made of a list of frames, taken through nothing else.
struct EstimatorRun {
    /// One entry per frame; nil where the estimator gave no sample.
    var outputs: [HeightSample?]
    var estimator: HeightEstimator

    init(_ method: HeightEstimator.Method, frames: [TraceFrame], config: HeightEstimator.Config = .init()) {
        var estimator = HeightEstimator(method: method, config: config)
        outputs = frames.map { estimator.ingest($0) }
        self.estimator = estimator
    }

    var samples: [HeightSample] { outputs.compactMap { $0 } }

    var heights: [Double] { samples.map(\.heightMM) }

    var peakToTroughMM: Double {
        (heights.max() ?? 0) - (heights.min() ?? 0)
    }

    var meanQuality: Double {
        samples.map(\.quality).reduce(0, +) / Double(max(samples.count, 1))
    }

    /// Millimetres of output per millimetre of true motion, by least squares. 1 is a perfect ruler,
    /// and a negative value means the heights run the wrong way.
    func gain(against truth: [HeightSample]) -> Double {
        let pairs = zip(truth, outputs).compactMap { true_, output in output.map { (true_.heightMM, $0.heightMM) } }
        let meanTruth = pairs.map(\.0).reduce(0, +) / Double(pairs.count)
        let meanOutput = pairs.map(\.1).reduce(0, +) / Double(pairs.count)
        let covariance = pairs.reduce(0) { $0 + ($1.0 - meanTruth) * ($1.1 - meanOutput) }
        let variance = pairs.reduce(0) { $0 + ($1.0 - meanTruth) * ($1.0 - meanTruth) }
        return covariance / variance
    }

    /// Largest gap between the output and the truth once both are measured from their own means.
    func worstErrorMM(against truth: [HeightSample]) -> Double {
        let pairs = zip(truth, outputs).compactMap { true_, output in output.map { (true_.heightMM, $0.heightMM) } }
        let offset = pairs.reduce(0) { $0 + ($1.1 - $1.0) } / Double(pairs.count)
        return pairs.map { abs($0.1 - $0.0 - offset) }.max() ?? .infinity
    }
}
