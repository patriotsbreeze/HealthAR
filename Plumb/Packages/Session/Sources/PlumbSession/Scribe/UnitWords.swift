/// The unit and linking words that can follow a number.
enum UnitWords {
    static let centimetres: Set<String> = ["cm", "centimetre", "centimetres", "centimeter", "centimeters"]
    static let millimetres: Set<String> = ["mm", "millimetre", "millimetres", "millimeter", "millimeters"]
    static let seconds: Set<String> = ["s", "sec", "secs", "second", "seconds"]
    static let minutes: Set<String> = ["min", "mins", "minute", "minutes"]
    static let percent: Set<String> = ["percent", "pct"]
    /// "per cent", written as two words.
    static let percentPair = (first: "per", second: "cent")
    static let percentSign: Character = "%"
    /// Words that turn a following "minute" into a rate: "per minute", "a minute".
    static let ratePer: Set<String> = ["per", "a", "each", "every"]
    static let rateSlash: Character = "/"
    static let rateWhole: Set<String> = ["bpm", "cpm"]
    /// Hyphens that may join a number to its unit: "9-second".
    static let hyphens: Set<Character> = ["-", "\u{2010}", "\u{2011}"]
    /// Links between two numbers that share one unit: "4.5 to 5.5 cm", "3, 5 and 9 seconds".
    static let rangeWords: Set<String> = ["to", "and", "or", "through"]
    static let rangeMarks: Set<Character> = ["-", "\u{2010}", "\u{2011}", "\u{2013}", "\u{2014}", ","]
    /// Links between the minutes and the seconds of one length of time: "6 minutes and 40 seconds".
    static let joinWords: Set<String> = ["and"]
    static let joinMarks: Set<Character> = [","]
    static let meridiems: [String: Meridiem] = ["am": .am, "pm": .pm]
    /// Beginnings of the nouns a bare count can be tied to.
    static let pauseNoun = "pause"
    static let compressionNoun = "compression"
}
