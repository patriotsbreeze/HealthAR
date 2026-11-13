import Foundation
import PlumbContracts
import PlumbGeometry

/// Everything a replay found in one trace.
public struct ReplayResult: Sendable {
    /// The recording this came from.
    public var traceFingerprint: TraceFingerprint
    /// The height method used.
    public var method: HeightEstimator.Method
    /// Where the range came from.
    public var range: RangeSource
    /// The gain every height was multiplied by.
    public var gain: Gain
    /// Frames in the trace.
    public var frameCount: Int
    /// Frames that gave a height sample.
    public var sampleCount: Int
    /// Times the phone placed the hands box again during the recording; the estimator restarted each time.
    public var placementCount: Int
    /// Time of the first and the last frame, in seconds since the phone's session started. Nil for an empty trace.
    public var span: ClosedRange<TimeInterval>?
    /// Every compression the analyzer counted, in order.
    public var strokes: [StrokeRow]
    /// Seconds the analyzer spent locked between the first and the last frame.
    public var lockedSeconds: Double
    /// Median straight-line distance from the camera to the hands over the frames that had one, in metres.
    public var rangeMedianM: Double?

    /// The numbers that sum the replay up.
    public var summary: ReplaySummary { ReplaySummary(self) }
}

/// One counted compression, and when the analyzer said so.
public struct StrokeRow: Sendable, Equatable {
    /// The compression as the analyzer reported it, depth already multiplied by the gain.
    public var compression: Compression
    /// Time of the sample whose arrival made the analyzer report it.
    public var reportedAt: TimeInterval

    /// A row from a compression and the time it was reported.
    public init(compression: Compression, reportedAt: TimeInterval) {
        self.compression = compression
        self.reportedAt = reportedAt
    }

    /// 1 for the first compression.
    public var index: Int { compression.index }
    /// When the hands were deepest.
    public var t: TimeInterval { compression.tBottom }
    /// Top of the stroke minus its deepest point, in millimetres.
    public var depthMM: Double { compression.depthMM }
    /// Seconds since the previous deepest point; nil for the first after a pause or a loss of signal.
    public var intervalS: Double? { compression.intervalS }
    /// Trust at the moment it was measured.
    public var lock: LockState { compression.lock }
    /// Seconds of trace time from the deepest point to the report. The phone's own processing and
    /// the hop to the main thread come on top of this.
    public var delayS: Double { reportedAt - compression.tBottom }
}
