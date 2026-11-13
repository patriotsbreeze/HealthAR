import Foundation
import PlumbContracts
import PlumbGeometry
import PlumbSignal

/// Runs a recorded trace through the same height estimator and compression analyzer the phone runs.
///
/// The phone feeds every recorded frame to its estimator, the very frame it writes to the trace, so
/// replaying the frames in order rebuilds the samples it measured. Two things differ, and both are
/// stated here rather than hidden:
/// - The phone's estimator may have been running before the recording began. The replay starts
///   fresh at the first recorded frame, so its first second or two can differ; heights are relative,
///   so after that only a constant offset remains.
/// - The phone ticks the analyzer on a wall-clock timer. The replay ticks it on an even beat of
///   trace time, which only moves when a pause or a loss of signal is noticed, by under a tick.
public enum Replay {
    /// Replays `trace` with `settings` and gathers what the analyzer counted.
    /// Throws `ReplayFailure.alongRayNeedsRange` for the along-ray method with an assumed range.
    public static func run(_ trace: RecordedTrace, settings: ReplaySettings = .init()) throws -> ReplayResult {
        if case .assumed = settings.range, settings.method == .alongRay { throw ReplayFailure.alongRayNeedsRange }
        var run = Run(settings: settings)
        for frame in trace.frames {
            run.take(frame)
        }
        let span = trace.frames.first.flatMap { first in trace.frames.last.map { first.t...max(first.t, $0.t) } }
        return ReplayResult(traceFingerprint: trace.fingerprint, method: settings.method, range: settings.range,
                            gain: settings.gain, frameCount: trace.frames.count, sampleCount: run.sampleCount,
                            placementCount: run.placementCount, span: span, strokes: run.strokes,
                            lockedSeconds: span.map { run.lock.lockedSeconds(until: $0.upperBound) } ?? 0,
                            rangeMedianM: Stats.median(run.ranges))
    }
}

/// The state carried from frame to frame during one replay.
private struct Run {
    let settings: ReplaySettings
    var estimator: HeightEstimator
    var analyzer: CompressionAnalyzer
    var placements = ReseedWatch()
    var ticks: TickClock
    var lock = LockClock()
    var strokes: [StrokeRow] = []
    var ranges: [Double] = []
    var sampleCount = 0
    var placementCount = 0

    init(settings: ReplaySettings) {
        self.settings = settings
        estimator = HeightEstimator(method: settings.method, config: settings.estimator)
        analyzer = CompressionAnalyzer(config: settings.analyzer, targets: settings.targets)
        ticks = TickClock(ticksPerSecond: settings.ticksPerSecond)
    }

    mutating func take(_ recorded: TraceFrame) {
        let frame: TraceFrame
        switch settings.range {
        case .measured: frame = recorded
        case .assumed(let metres): frame = CameraOnly.frame(recorded, assumedRangeM: metres)
        }
        lock.start(at: frame.t)
        if placements.isNewPlacement(frame) {
            // What the phone does when the hands box is placed again: heights start over.
            estimator.reset()
            placementCount += 1
        }
        let sample = estimator.ingest(frame)
        if let rangeM = estimator.rangeM { ranges.append(rangeM) }
        for t in ticks.due(before: frame.t) {
            note(analyzer.tick(now: t), at: t)
        }
        guard var sample else { return }
        sampleCount += 1
        sample.heightMM *= settings.gain.value
        note(analyzer.ingest(sample), at: sample.t)
    }

    private mutating func note(_ events: [SignalEvent], at t: TimeInterval) {
        for event in events {
            switch event {
            case .compression(let compression):
                strokes.append(StrokeRow(compression: compression, reportedAt: t))
            case .lockChanged(let state, let at):
                lock.change(to: state, at: at)
            case .pauseStarted, .pauseEnded:
                break
            }
        }
    }
}
