import Foundation

/// The fixed word lists behind `KeywordIntentClassifier`.
///
/// Each entry is a phrase of one or more whole words, matched in order against the question's words
/// once they are folded to plain lower case. Apostrophes are dropped first, so "how's" is the one word
/// "hows". Single words that often open an unrelated sentence ("quick question", "so far") are left
/// out, or kept only inside a longer phrase.
enum IntentKeywords {
    /// Words about a person rather than the compressions. A question holding any of them is never
    /// answered from the measurements, whatever else it asks, so a number can never be heard as news
    /// about someone's condition.
    static let condition: Set<String> = [
        "breathing", "breathe", "breathes", "breathed", "breath", "breaths",
        "pulse", "pulses", "heart", "hearts", "heartbeat",
        "alive", "dead", "die", "dies", "died", "dying", "death",
        "survive", "survives", "survived", "surviving", "survival", "save", "saved", "saving",
        "conscious", "unconscious", "consciousness", "awake", "responsive", "unresponsive", "responding",
        "rib", "ribs", "bone", "bones", "broke", "broken", "fracture",
        "hurt", "hurts", "hurting", "injury", "injured", "bleeding", "blood", "choking", "choke",
        "drug", "drugs", "medicine", "medication", "overdose",
        "aed", "defibrillator", "defib", "shock", "shocks",
        "911", "ambulance", "paramedic", "paramedics", "ems", "hospital", "doctor", "nurse",
        "diagnose", "diagnosis",
    ]

    /// Words naming the person rather than the one pushing. "How is he doing?" asks about someone's
    /// condition without a single word from `condition`, and "doing" would otherwise read it as asking
    /// how the compressions are going. A question naming the person is treated like one about their
    /// condition, even when it is about the pushing ("am I pushing hard enough on him"): it gets the
    /// fixed list of topics instead of a number, which is the safe way to be wrong.
    static let person: Set<String> = [
        "he", "she", "him", "her", "his", "hers",
        "patient", "person", "victim", "casualty",
        "man", "woman", "guy", "girl", "boy", "child", "kid", "baby",
    ]

    /// Phrases that ask how things will turn out for someone, as in "will he make it" or "is she going to
    /// be okay". Treated like `condition`.
    static let outcome = phrases("make it", "going to be")

    static let rate = phrases(
        "rate", "rates", "fast", "faster", "fastest", "slow", "slower", "slowest", "slowly",
        "speed", "speeding", "pace", "pacing", "tempo", "too quick", "quicker", "quickly",
        "rhythm", "beat", "beats", "metronome", "rush", "rushing", "rushed", "hurry",
        "per minute", "per min", "a minute", "each minute", "every minute", "bpm", "cpm")

    /// Units that turn "how many" into a question about a measurement rather than the count, as in
    /// "how many a minute" or "how many centimetres".
    static let units = phrases(
        "per minute", "per min", "a minute", "each minute", "every minute", "bpm", "cpm",
        "cm", "centimetre", "centimetres", "centimeter", "centimeters", "inch", "inches")

    static let depth = phrases(
        "depth", "deep", "deeper", "deepest", "deeply", "shallow", "shallower",
        "hard", "harder", "hardest", "soft", "softer", "softly", "gentle", "gently",
        "strong", "stronger", "firm", "firmer", "firmly", "force", "forceful", "pressure",
        "cm", "centimetre", "centimetres", "centimeter", "centimeters", "inch", "inches",
        "far down", "far enough")

    static let pauses = phrases(
        "pause", "pauses", "paused", "pausing", "stop", "stops", "stopped", "stopping",
        "break", "breaks", "gap", "gaps", "interrupt", "interrupted", "interruption", "interruptions",
        "rest", "rested", "resting", "idle", "downtime", "down time",
        "hands off", "hand off", "hands on", "off the chest")

    static let count = phrases("count", "counted", "counting", "how many", "number", "total", "tally")

    /// Asking how it is going in general. Used only when no single topic above was named.
    static let overall = phrases(
        "how am i", "how im", "howm i", "how are we", "how are things", "how is everything", "hows everything",
        "how is it going", "hows it going", "how is this going", "hows this going", "how is that", "hows that",
        "how is it looking", "hows it looking", "how does it look", "how does this look", "how does that look",
        "how do i look", "how did i do", "how is my", "hows my", "how are my", "how well", "how good",
        "am i doing", "doing ok", "doing okay", "doing well", "doing good", "doing alright", "doing all right",
        "doing fine", "doing it right", "doing this right", "doing it correctly", "doing this correctly",
        "doing it properly", "doing this properly", "doing it wrong", "doing this wrong",
        "am i ok", "am i okay", "am i good", "am i right", "am i alright", "am i all right",
        "is this right", "is this good", "is this ok", "is this okay", "is this correct",
        "is that right", "is that good", "is that ok", "is that okay",
        "is it good", "is it ok", "is it okay", "is it right", "is it working",
        "feedback", "status", "update", "overall", "summary", "progress", "report", "quality", "score",
        "my cpr", "the cpr", "my compressions", "the compressions")

    private static func phrases(_ items: String...) -> [[String]] {
        items.map { $0.split(separator: " ").map(String.init) }
    }
}
