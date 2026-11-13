import Foundation
import PlumbContracts

/// What really happened during a recording, as measured outside the phone.
public struct Truth: Sendable, Equatable {
    /// The travel of every push, in millimetres, set by the rig: a stop, a spacer, a known spring.
    public var depthMM: Double?
    /// The rate pushed at, a minute, counted or set by a metronome.
    public var ratePerMin: Double?

    /// The truth as far as it is known; leave out what was not measured.
    public init(depthMM: Double? = nil, ratePerMin: Double? = nil) {
        self.depthMM = depthMM
        self.ratePerMin = ratePerMin
    }

    /// True when nothing is known, so there is nothing to score against.
    public var isEmpty: Bool { depthMM == nil && ratePerMin == nil }
}

/// How a set of measurements missed the truth. Errors are measured minus truth.
public struct ErrorStats: Sendable, Equatable {
    /// How many measurements were compared.
    public var n: Int
    /// The median of the errors' sizes.
    public var medianAbsoluteError: Double
    /// The mean error, with its sign: positive reads high.
    public var bias: Double
    /// The most negative error.
    public var lowest: Double
    /// The most positive error.
    public var highest: Double

    /// Sums up the errors; nil when there are none.
    public init?(errors: [Double]) {
        guard let lowest = errors.min(), let highest = errors.max(),
              let median = Stats.median(errors.map(abs)) else { return nil }
        n = errors.count
        medianAbsoluteError = median
        bias = errors.reduce(0, +) / Double(errors.count)
        self.lowest = lowest
        self.highest = highest
    }
}

/// A replay scored against the truth.
public struct TruthReport: Sendable, Equatable {
    /// Depth of the compressions measured while locked, the ones the coach judges. Nil without a true depth or such compressions.
    public var depthLocked: ErrorStats?
    /// Depth of every counted compression.
    public var depthAll: ErrorStats?
    /// The rate each interval implies, 60 over the interval, against the true rate.
    public var rate: ErrorStats?
}

extension ReplayResult {
    /// Scores the replay against the truth. Refuses a replay whose gain was fitted on this same
    /// recording: a score is only worth anything on a recording the gain has never seen.
    public func compared(with truth: Truth) throws -> TruthReport {
        if gain.fittedOn == traceFingerprint { throw ReplayFailure.scoredOnCalibrationTrace }
        func depthErrors(_ rows: [StrokeRow]) -> ErrorStats? {
            truth.depthMM.flatMap { depthMM in ErrorStats(errors: rows.map { $0.depthMM - depthMM }) }
        }
        let rateErrors = truth.ratePerMin.flatMap { ratePerMin in
            ErrorStats(errors: strokes.compactMap(\.intervalS).filter { $0 > 0 }.map { 60 / $0 - ratePerMin })
        }
        return TruthReport(depthLocked: depthErrors(strokes.filter { $0.lock == .locked }),
                           depthAll: depthErrors(strokes), rate: rateErrors)
    }
}

/// Fits a gain on one recording, to be scored on another.
public enum GainFit {
    /// The gain that would make the median locked depth of `result` equal `truthDepthMM`, on top of
    /// the gain it already ran with, marked with the recording it came from so that recording is
    /// never scored with it.
    public static func fit(_ result: ReplayResult, truthDepthMM: Double) throws -> FittedGain {
        let locked = result.strokes.filter { $0.lock == .locked }.map(\.depthMM)
        guard let median = Stats.median(locked), median > 0 else { throw ReplayFailure.nothingToFit }
        let gain = Gain(value: result.gain.value * truthDepthMM / median, fittedOn: result.traceFingerprint)
        return FittedGain(gain: gain, strokeCount: locked.count, medianDepthMM: median, truthDepthMM: truthDepthMM)
    }
}

/// A gain and what it was fitted from.
public struct FittedGain: Sendable, Equatable {
    /// The gain, marked with the recording it was fitted on.
    public var gain: Gain
    /// Locked compressions it was fitted from.
    public var strokeCount: Int
    /// Their median depth before this fit, in millimetres.
    public var medianDepthMM: Double
    /// The true depth it was fitted to.
    public var truthDepthMM: Double
}
