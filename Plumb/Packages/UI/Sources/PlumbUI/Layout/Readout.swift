import Foundation

/// Turns measured numbers into the short strings the screens show, with no more precision than a reader needs.
enum Readout {
    /// The space between a number and its unit. It does not break, so "5 cm" is never split over two lines.
    static let unitSpace = "\u{00A0}"

    /// A rate as a whole number per minute.
    static func rate(_ perMin: Double) -> String {
        String(Int(perMin.rounded()))
    }

    /// Elapsed time as minutes and seconds, such as "6:40".
    static func elapsed(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }

    /// A share of 0...1 as a whole percentage, such as "71%".
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// A depth in millimetres as centimetres, such as "5 cm" or "5.5 cm".
    static func centimetres(_ mm: Double) -> String {
        short(mm / 10) + unitSpace + "cm"
    }

    /// Whole seconds counted so far, such as "4". Counts up, so it never rounds ahead.
    static func wholeSeconds(_ seconds: Double) -> String {
        String(max(0, Int(seconds)))
    }

    /// A short duration, such as "1.2 s" or "2 s".
    static func seconds(_ seconds: Double) -> String {
        short(seconds) + unitSpace + "s"
    }

    /// A number to one decimal place at most. A whole number shows no decimal, so none is invented.
    private static func short(_ value: Double) -> String {
        let tenths = (value * 10).rounded() / 10
        return tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
    }
}
