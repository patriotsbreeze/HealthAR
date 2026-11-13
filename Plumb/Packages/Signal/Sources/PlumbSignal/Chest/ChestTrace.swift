import Foundation

/// The last stretch of chest height as evenly spaced values, for a moving line.
///
/// The values are drawn about the median of what is shown, so the line stays centred without any single
/// point being bent: subtracting a moving baseline point by point would turn a chest held still into a slow sag.
public struct ChestTrace: Sendable, Equatable {
    /// Seconds between neighbouring values.
    public var stepS: Double
    /// Height in millimetres, up positive, oldest first and newest last. Nil where nothing was measured.
    public var valuesMM: [Double?]
    /// The threshold band over the window being judged, in the same millimetres: its height is the threshold,
    /// centred between the highest and lowest values in that window. A line that fits inside it is not movement.
    /// Nil while unmeasured.
    public var bandMM: ClosedRange<Double>?
    /// Seconds the band covers, ending at the newest value.
    public var bandSpanS: Double

    /// Share of the trace's width, counted from the right, that the band covers. 0...1.
    public var bandShare: Double {
        let spanS = Double(valuesMM.count) * stepS
        guard spanS > 0 else { return 0 }
        return min(1, max(0, bandSpanS / spanS))
    }

    /// A trace with nothing measured in it.
    static func blank(_ config: ChestMovementAnalyzer.Config) -> ChestTrace {
        ChestTrace(stepS: config.binS, valuesMM: Array(repeating: nil, count: config.traceSlots),
                   bandMM: nil, bandSpanS: config.windowS)
    }
}

extension ChestMovementAnalyzer.Config {
    /// How many values a trace holds.
    var traceSlots: Int {
        max(1, Int((traceS / binS).rounded()))
    }
}
