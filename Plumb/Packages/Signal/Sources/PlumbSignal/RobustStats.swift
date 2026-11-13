import Foundation

/// Summaries that a single wild value cannot drag far.
enum RobustStats {
    /// The middle value, or the mean of the two middle values. Nil for no values.
    static func median(_ values: [Double]) -> Double? {
        quantile(0.5, ofSorted: values.sorted())
    }

    /// Width of the middle half of the values, scaled so that for bell-shaped data it matches the
    /// standard deviation. One wild value in five does not move it; two clusters do.
    /// Nil below two values, where spread means nothing.
    static func spread(_ values: [Double]) -> Double? {
        guard values.count >= 2 else { return nil }
        let sorted = values.sorted()
        guard let lower = quantile(0.25, ofSorted: sorted), let upper = quantile(0.75, ofSorted: sorted) else {
            return nil
        }
        return (upper - lower) / bellCurveMiddleHalf
    }

    /// The value a given share of the way through sorted values, reading between neighbours.
    private static func quantile(_ share: Double, ofSorted sorted: [Double]) -> Double? {
        guard let last = sorted.last else { return nil }
        let position = share * Double(sorted.count - 1)
        let below = Int(position.rounded(.down))
        guard below + 1 < sorted.count else { return last }
        let part = position - Double(below)
        return sorted[below] + part * (sorted[below + 1] - sorted[below])
    }

    /// Width of the middle half of a normal distribution, in standard deviations.
    private static let bellCurveMiddleHalf = 1.349
}
