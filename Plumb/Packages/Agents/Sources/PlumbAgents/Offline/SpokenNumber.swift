import Foundation

/// Measurements turned into the numbers said aloud, rounded no finer than they are measured.
///
/// Rate is said to the whole compression per minute and depth to the half centimetre. A value that
/// is not a real reading (not a number, infinite, zero or below, or absurdly large) is treated as not
/// measured, so nothing here can trap on a bad value or say a made-up number.
enum SpokenNumber {
    /// The value when it is a usable reading, otherwise nil.
    static func reading(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value < 100_000 else { return nil }
        return value
    }

    /// The nearest whole number. Only for values that passed `reading`.
    static func whole(_ value: Double) -> Int {
        Int(value.rounded())
    }

    /// Millimetres rounded to the nearest half centimetre, still in millimetres, for comparing what
    /// will be said with the targets.
    static func halfCentimetreMM(_ millimetres: Double) -> Double {
        (millimetres / 5).rounded() * 5
    }

    /// Millimetres as centimetres to the nearest half: "5", "5.5", "0.5".
    static func centimetres(_ millimetres: Double) -> String {
        let halves = Int((millimetres / 5).rounded())
        return halves.isMultiple(of: 2) ? "\(halves / 2)" : "\(halves / 2).5"
    }

    /// A share between 0 and 1 as a whole percentage, or nil when it is not a usable share.
    static func percent(_ fraction: Double?) -> Int? {
        guard let fraction, fraction.isFinite, (0...1).contains(fraction) else { return nil }
        return Int((fraction * 100).rounded())
    }

    /// Whole seconds of a pause, or nil when the length is not usable.
    static func seconds(_ value: Double) -> Int? {
        guard value.isFinite, value >= 0, value < 100_000 else { return nil }
        return Int(value.rounded())
    }
}
