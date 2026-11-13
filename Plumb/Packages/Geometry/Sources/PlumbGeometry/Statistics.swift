import Foundation

/// The few order statistics the patch reader and the running windows share.
enum Stats {
    /// The value a fraction `q` (0...1) of the way through an already sorted list, blending neighbours.
    static func quantile(ofSorted sorted: [Double], _ q: Double) -> Double? {
        guard let first = sorted.first else { return nil }
        guard sorted.count > 1 else { return first }
        let position = min(max(q, 0), 1) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    /// The middle value of an unsorted list.
    static func median(_ values: [Double]) -> Double? {
        quantile(ofSorted: values.sorted(), 0.5)
    }

    /// Sample standard deviation; nil until there are two values.
    static func standardDeviation(_ values: [Double]) -> Double? {
        guard values.count > 1 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let squares = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return (squares / Double(values.count - 1)).squareRoot()
    }
}
