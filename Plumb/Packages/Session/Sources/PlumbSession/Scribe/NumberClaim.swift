/// One number a sentence states, with the kind of quantity its unit says it is.
struct NumberClaim: Equatable {
    enum Kind: Equatable {
        /// A bare count, tied to a noun when one follows the number.
        case count(CountNoun?)
        case depthMM
        case depthCM
        case rate
        case seconds
        case minutes
        case percent
    }

    var value: Double
    /// Digits written after the decimal point: the precision the sentence claims.
    var decimals: Int
    var kind: Kind
    /// The number with its unit, for refusal messages: "5.3 cm", "6 min 40 s".
    var written: String
    /// The number alone, as written. Nil when the claim was put together from two numbers.
    var bareNumber: String?
}

/// The things a sentence can count.
enum CountNoun: Equatable {
    case compressions
    case pauses
}

/// A time of day a sentence states.
struct ClockClaim: Equatable {
    var hour: Int
    var minute: Int
    var second: Int?
    var meridiem: Meridiem?
    var written: String

    /// The hour on a 24-hour clock, or nil when the written hour makes no sense with am or pm.
    var hourOfDay: Int? {
        guard let meridiem else { return hour }
        guard (1...Meridiem.hoursPerHalfDay).contains(hour) else { return nil }
        let hourInHalf = hour % Meridiem.hoursPerHalfDay
        return meridiem == .pm ? hourInHalf + Meridiem.hoursPerHalfDay : hourInHalf
    }
}

/// Which half of the day a 12-hour clock time is in.
enum Meridiem: Equatable {
    case am
    case pm

    static let hoursPerHalfDay = 12
}

/// Everything number-like found in one sentence.
struct SentenceReading: Equatable {
    var numbers: [NumberClaim] = []
    var clocks: [ClockClaim] = []
    /// A number-like word or character that cannot be checked, as written. Nil when there is none.
    var unreadable: String?
}
