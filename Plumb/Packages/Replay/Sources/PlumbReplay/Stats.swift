import Foundation

/// The few order statistics a replay is summed up with.
enum Stats {
    /// The value a share `q` (0...1) of the way through, interpolating between neighbours. Nil when empty.
    static func quantile(_ values: [Double], _ q: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let position = min(max(q, 0), 1) * Double(sorted.count - 1)
        let below = Int(position.rounded(.down))
        let above = min(below + 1, sorted.count - 1)
        let fraction = position - Double(below)
        return sorted[below] * (1 - fraction) + sorted[above] * fraction
    }

    static func median(_ values: [Double]) -> Double? {
        quantile(values, 0.5)
    }

    /// Upper quartile minus lower quartile: how widely the middle half spreads. Nil when empty.
    static func interquartileRange(_ values: [Double]) -> Double? {
        guard let lower = quantile(values, 0.25), let upper = quantile(values, 0.75) else { return nil }
        return upper - lower
    }
}
