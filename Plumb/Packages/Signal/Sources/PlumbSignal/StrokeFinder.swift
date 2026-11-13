import Foundation

/// A down-and-up movement that may be a compression. Not yet checked for being a believable one.
struct StrokeCandidate: Equatable, Sendable {
    /// When the hands left the top.
    var tTop: TimeInterval
    /// When the hands were deepest.
    var tBottom: TimeInterval
    var topMM: Double
    var bottomMM: Double
    /// Average height of the readings around the deepest point.
    var bottomSurroundMM: Double

    var depthMM: Double { topMM - bottomMM }
    var descentS: Double { tBottom - tTop }
    /// How far below the top the hands stayed around the deepest point. A one-sample dip scores low here.
    var heldDepthMM: Double { topMM - bottomSurroundMM }
}

/// Finds strokes in the cleaned, smoothed height.
///
/// The top is tracked as an upper envelope that rises with the hands at once and sinks only slowly.
/// A stroke begins when the hands drop a set distance below it, and its deepest point is confirmed
/// when they have come back up a set distance. Tracking restarts from each deepest point, so a top
/// that has moved (leaning, re-seating) is picked up on the very next stroke.
struct StrokeFinder: Sendable {
    private enum Phase: Sendable {
        /// Hands at or returning to the top; waiting for the next drop.
        case resting
        /// Hands going down; waiting for them to turn.
        case descending(Descent)
    }

    private struct Descent: Sendable {
        var startedAt: TimeInterval
        var top: TopMeasure
        var lowestSmoothMM: Double
    }

    private let config: CompressionAnalyzer.Config
    private var window: SampleWindow
    private var phase = Phase.resting
    /// Upper envelope of the smoothed height since the last deepest point.
    private var envelopeMM: Double?
    /// Readings before this moment belong to an earlier stroke and say nothing about the next top.
    private var topSearchStart = -TimeInterval.infinity
    /// Top of the last stroke, and until when it still anchors the live depth.
    private var heldTop: (heightMM: Double, until: TimeInterval)?
    private var lastT: TimeInterval?
    private var previousSmoothMM: Double?

    /// How far below the current top the smoothed height is. Never negative.
    private(set) var liveDepthMM = 0.0

    init(config: CompressionAnalyzer.Config) {
        self.config = config
        window = SampleWindow(capacity: config.historyCapacity, spanS: config.historyS)
    }

    /// Takes the next reading. Returns a candidate at the moment its deepest point is confirmed.
    mutating func process(_ reading: CleanReading, smoothMM: Double) -> StrokeCandidate? {
        let elapsed = lastT.map { reading.t - $0 } ?? 0
        lastT = reading.t
        window.append(TracePoint(t: reading.t, rawMM: reading.heightMM, smoothMM: smoothMM))

        var candidate: StrokeCandidate?
        switch phase {
        case .resting:
            rest(at: reading.t, smoothMM: smoothMM, elapsed: elapsed)
        case .descending(let descent):
            candidate = descend(descent, at: reading.t, smoothMM: smoothMM)
        }
        previousSmoothMM = smoothMM
        liveDepthMM = max(0, currentTop(at: reading.t, smoothMM: smoothMM) - smoothMM)
        return candidate
    }

    private mutating func rest(at t: TimeInterval, smoothMM: Double, elapsed: Double) {
        // A height counts only once two readings in a row have reached it, so that one stray
        // reading can neither lift the top nor start a stroke.
        let earlier = previousSmoothMM ?? smoothMM
        let sunk = (envelopeMM ?? smoothMM) - config.topDroopMMPerS * elapsed
        let envelope = max(min(smoothMM, earlier), sunk)
        envelopeMM = envelope
        guard envelope - max(smoothMM, earlier) >= config.strokeStartDropMM,
              let top = TopDwell.measure(in: window, after: topSearchStart, bandMM: config.topBandMM,
                                         lagS: config.smoothingTimeS)
        else { return }
        phase = .descending(Descent(startedAt: t, top: top, lowestSmoothMM: smoothMM))
    }

    private mutating func descend(_ descent: Descent, at t: TimeInterval, smoothMM: Double) -> StrokeCandidate? {
        var descent = descent
        descent.lowestSmoothMM = min(descent.lowestSmoothMM, smoothMM)

        if smoothMM >= descent.lowestSmoothMM + config.bottomConfirmRiseMM {
            let bottom = TroughFit.measure(in: window, since: descent.startedAt,
                                           halfWindowS: config.bottomFitHalfWindowS)
            restartTracking(at: t, smoothMM: smoothMM)
            heldTop = (descent.top.heightMM, t + config.topHoldS)
            return bottom.map {
                StrokeCandidate(tTop: descent.top.leftAt, tBottom: $0.t, topMM: descent.top.heightMM,
                                bottomMM: $0.heightMM, bottomSurroundMM: $0.surroundMM)
            }
        }
        if t - descent.startedAt > config.maxDescentS {
            // Too slow to be a compression: the hands have swayed or settled lower. Take this as the new top.
            restartTracking(at: t, smoothMM: smoothMM)
            heldTop = nil
            return nil
        }
        phase = .descending(descent)
        return nil
    }

    private mutating func restartTracking(at t: TimeInterval, smoothMM: Double) {
        phase = .resting
        envelopeMM = smoothMM
        topSearchStart = t
    }

    private func currentTop(at t: TimeInterval, smoothMM: Double) -> Double {
        if case .descending(let descent) = phase {
            return descent.top.heightMM
        }
        let envelope = envelopeMM ?? smoothMM
        if let heldTop, t < heldTop.until {
            return max(envelope, heldTop.heightMM)
        }
        return envelope
    }
}
