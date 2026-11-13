import Foundation
import PlumbContracts
import Testing
@testable import PlumbSignal

/// Everything one run of the analyzer produced, with the moment each event was handed back.
struct Playback {
    struct Reported {
        /// Time of the sample or tick whose call returned the event.
        var at: TimeInterval
        var event: SignalEvent
    }

    var reported: [Reported] = []
    var analyzer: CompressionAnalyzer
    /// Metrics as they stood right after each compression was reported.
    var metricsAfterStroke: [Metrics] = []

    var events: [SignalEvent] { reported.map(\.event) }

    var compressions: [Compression] {
        events.compactMap { if case .compression(let stroke) = $0 { stroke } else { nil } }
    }

    var locks: [LockState] {
        events.compactMap { if case .lockChanged(let lock, _) = $0 { lock } else { nil } }
    }

    var pauseStarts: [TimeInterval] {
        events.compactMap { if case .pauseStarted(let at) = $0 { at } else { nil } }
    }

    var pauseEnds: [(at: TimeInterval, duration: Double)] {
        events.compactMap { if case .pauseEnded(let at, let duration) = $0 { (at, duration) } else { nil } }
    }

    /// When the call that returned the first event matching `match` was made.
    func reportTime(where match: (SignalEvent) -> Bool) -> TimeInterval? {
        reported.first { match($0.event) }?.at
    }
}

/// Feeds samples to an analyzer the way the app does: every sample, plus a tick a few times a second.
func play(_ samples: [HeightSample], into analyzer: CompressionAnalyzer = CompressionAnalyzer(),
          tickEvery: TimeInterval = 0.2, until end: TimeInterval? = nil) -> Playback {
    var playback = Playback(analyzer: analyzer)
    var nextTick = (samples.first?.t ?? 0) + tickEvery

    func record(_ events: [SignalEvent], at t: TimeInterval, into playback: inout Playback) {
        for event in events {
            playback.reported.append(.init(at: t, event: event))
            if case .compression = event {
                playback.metricsAfterStroke.append(playback.analyzer.metrics)
            }
        }
    }

    for sample in samples {
        while nextTick < sample.t {
            record(playback.analyzer.tick(now: nextTick), at: nextTick, into: &playback)
            nextTick += tickEvery
        }
        record(playback.analyzer.ingest(sample), at: sample.t, into: &playback)
    }
    if let end {
        while nextTick <= end {
            record(playback.analyzer.tick(now: nextTick), at: nextTick, into: &playback)
            nextTick += tickEvery
        }
    }
    return playback
}

/// A steady stretch of compressions, the standard test signal.
func steady(rate: Double, depth: Double, seconds: Double = 20) -> [SyntheticSegment] {
    [SyntheticSegment(duration: seconds, ratePerMin: rate, depthMM: depth)]
}

/// A stretch of compressions that ends exactly at the top of a stroke, so no stroke is cut short.
func wholeStrokes(_ strokes: Int, rate: Double, depth: Double) -> SyntheticSegment {
    SyntheticSegment(duration: Double(strokes) * 60 / rate, ratePerMin: rate, depthMM: depth)
}

/// Samples of one steady stretch taken at uneven moments: each time stamp is moved by up to
/// `jitter` of a step either way, and the height is the true height at that moved moment.
func unevenSamples(rate: Double, depth: Double, seconds: Double, sampleHz: Double, noiseMM: Double,
                   jitter: Double, seed: UInt64) -> [HeightSample] {
    var rng = SplitMix64(seed: seed)
    let step = 1 / sampleHz
    return (0..<Int(seconds * sampleHz)).map { index in
        let t = max(0, (Double(index) + jitter * (2 * rng.nextUnit() - 1)) * step)
        let height = -depth * SyntheticSession.strokeShape(phase: t * rate / 60)
        return HeightSample(t: t, heightMM: height + noiseMM * rng.nextGaussian())
    }
}

/// Still hands with measurement noise and, optionally, a slow sway.
func idleSamples(seconds: Double, sampleHz: Double = 60, noiseMM: Double, swayMM: Double = 0,
                 swayHz: Double = 0, seed: UInt64 = 1) -> [HeightSample] {
    var rng = SplitMix64(seed: seed)
    return (0..<Int(seconds * sampleHz)).map { index in
        let t = Double(index) / sampleHz
        let sway = swayMM * sin(2 * .pi * swayHz * t)
        return HeightSample(t: t, heightMM: sway + noiseMM * rng.nextGaussian())
    }
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return .nan }
    let mid = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

/// The true deepest point closest in time to `t`.
func nearest(_ bottoms: [SyntheticSession.Truth.Bottom], to t: TimeInterval) -> SyntheticSession.Truth.Bottom? {
    bottoms.min { abs($0.t - t) < abs($1.t - t) }
}

/// One steady rhythm to test against: a rate and a depth.
struct Pace: Sendable, CustomTestStringConvertible {
    var rate: Double
    var depth: Double

    var testDescription: String { "\(Int(rate))/min at \(Int(depth)) mm" }

    /// The rates and depths the accuracy requirements are stated for.
    static let grid: [Pace] = [100, 110, 120].flatMap { rate in
        [35, 45, 55].map { Pace(rate: rate, depth: $0) }
    }
}

/// The ways samples can arrive.
enum Sampling: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case sixtyHz
    case thirtyHz
    case everySeventhDropped
    case unevenSpacing
    case thirtyHzEverySeventhDropped

    var testDescription: String { rawValue }

    /// The conditions the accuracy and timing requirements are stated for.
    static let required: [Sampling] = [.sixtyHz, .thirtyHz, .everySeventhDropped, .unevenSpacing]

    func samples(_ pace: Pace, seconds: Double = 20, noiseMM: Double = 2, seed: UInt64 = 1) -> [HeightSample] {
        let segments = steady(rate: pace.rate, depth: pace.depth, seconds: seconds)
        switch self {
        case .sixtyHz:
            return SyntheticSession.samples(segments, sampleHz: 60, noiseMM: noiseMM, seed: seed)
        case .thirtyHz:
            return SyntheticSession.samples(segments, sampleHz: 30, noiseMM: noiseMM, seed: seed)
        case .everySeventhDropped:
            return SyntheticSession.samples(segments, sampleHz: 60, noiseMM: noiseMM, dropEvery: 7, seed: seed)
        case .unevenSpacing:
            return unevenSamples(rate: pace.rate, depth: pace.depth, seconds: seconds, sampleHz: 60,
                                 noiseMM: noiseMM, jitter: 0.3, seed: seed)
        case .thirtyHzEverySeventhDropped:
            return SyntheticSession.samples(segments, sampleHz: 30, noiseMM: noiseMM, dropEvery: 7, seed: seed)
        }
    }
}
