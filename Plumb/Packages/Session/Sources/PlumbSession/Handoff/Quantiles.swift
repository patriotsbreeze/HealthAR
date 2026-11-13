/// Order statistics used for "typical" values, which one wild reading must not move.
enum Quantiles {
    /// The value below which the share `q` (0 to 1) of `values` falls, interpolating between
    /// neighbours. Nil when there are no values.
    static func quantile(_ values: [Double], _ q: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let position = min(1, max(0, q)) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let share = position - Double(lower)
        return sorted[lower] + share * (sorted[upper] - sorted[lower])
    }

    /// The middle value, or the mean of the two middle values. Nil when there are no values.
    static func median(_ values: [Double]) -> Double? {
        quantile(values, middle)
    }

    private static let middle = 0.5
}
