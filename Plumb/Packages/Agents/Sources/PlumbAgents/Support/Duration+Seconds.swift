import Foundation

extension Duration {
    /// The length in seconds, for APIs and sentences that want a plain number.
    var inSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

extension Double {
    /// The number as text with one decimal place, the form used wherever a measurement is shown to a model.
    var oneDecimal: String {
        String(format: "%.1f", self)
    }
}
