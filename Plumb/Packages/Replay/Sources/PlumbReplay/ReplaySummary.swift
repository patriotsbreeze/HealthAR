import Foundation
import PlumbContracts

/// The few numbers that sum up a replay.
public struct ReplaySummary: Sendable, Equatable {
    /// Compressions counted.
    public var count: Int
    /// Of those, the ones measured while locked: the only ones whose depth the coach judges.
    public var lockedCount: Int
    /// Compressions a minute, from the median interval between deepest points. Nil without an interval.
    public var ratePerMin: Double?
    /// Median depth of every counted compression, in millimetres.
    public var depthMedianMM: Double?
    /// Interquartile range of those depths, in millimetres.
    public var depthSpreadMM: Double?
    /// Share of the trace, first frame to last, spent locked. Nil for a trace with no length.
    public var lockedShare: Double?
    /// Median seconds of trace time from a deepest point to the sample that revealed it.
    public var delayMedianS: Double?
    /// Longest of those delays.
    public var delayLongestS: Double?
    /// Median distance from the camera to the hands, in metres.
    public var rangeMedianM: Double?

    /// Sums up a replay.
    public init(_ result: ReplayResult) {
        let strokes = result.strokes
        let depths = strokes.map(\.depthMM)
        let delays = strokes.map(\.delayS)
        count = strokes.count
        lockedCount = strokes.filter { $0.lock == .locked }.count
        ratePerMin = Stats.median(strokes.compactMap(\.intervalS)).flatMap { $0 > 0 ? 60 / $0 : nil }
        depthMedianMM = Stats.median(depths)
        depthSpreadMM = Stats.interquartileRange(depths)
        let length = result.span.map { $0.upperBound - $0.lowerBound } ?? 0
        lockedShare = length > 0 ? min(1, result.lockedSeconds / length) : nil
        delayMedianS = Stats.median(delays)
        delayLongestS = delays.max()
        rangeMedianM = result.rangeMedianM
    }
}
