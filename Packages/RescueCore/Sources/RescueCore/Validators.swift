import Foundation

public struct SentinelFlag: Sendable, Equatable, Codable {
    public enum Category: String, Sendable, Equatable, Codable, CaseIterable {
        case pulseCheck = "pulse_check"
        case stopCpr = "stop_cpr"
        case dose
        case deathStatement = "death_statement"
        case reassurance
        case diagnosis
        case identity
        case discourageEmergency = "discourage_emergency"
        case selfTransport = "self_transport"
        case straighten
        case selfCalling = "self_calling"

        public static let arrestCases: [Category] = [.pulseCheck, .stopCpr, .dose, .deathStatement, .reassurance]
        public static let awakeCases: [Category] = [
            .pulseCheck, .dose, .diagnosis, .identity, .discourageEmergency, .selfTransport, .straighten, .selfCalling,
        ]
        /// Arrest only, on purpose. Whatever walks this list expects core to have a correction, and
        /// core's table never holds an awake category.
        public static let allCases: [Category] = arrestCases
    }

    public var category: Category
    public var excerpt: String

    public init(category: Category, excerpt: String) {
        self.category = category
        self.excerpt = excerpt
    }
}

/// Which lines are wrong depends on the patient. "They should rest" is a stop-CPR line on the arrest
/// path and ordinary advice for someone awake.
public enum ValidatorProfile: String, Sendable, Equatable {
    case arrest, awake

    public var categories: [SentinelFlag.Category] {
        switch self {
        case .arrest: SentinelFlag.Category.arrestCases
        case .awake: SentinelFlag.Category.awakeCases
        }
    }
}

/// Checks model transcripts for lines it must not say. Transcripts come with the audio, which arrives
/// several times faster than it plays, so a clause is usually flagged before it's heard, though not
/// always, and transcripts may include unspoken words. It is a backstop and not a guarantee.
public enum TranscriptValidator {
    private static let subject = #"(he|she|they|the patient|the person|patient|person)"#
    private static let okay = #"(fine|okay|ok|alright|all right|stable)"#

    private static let rules: [(SentinelFlag.Category, String)] = [
        (.pulseCheck, #"\b(check|checking|feel|feeling|find|look for|take)\b[^.?!]{0,30}\bpulse\b"#),
        (.stopCpr, #"\b(stop|stopping|pause|quit|hold off)\b[^.?!]{0,30}\b(compressions?|cpr|pushing|pumping)\b"#),
        (.stopCpr, #"\b(can|may|should)\s+(stop|rest|quit|take a break)\b"#),
        (.stopCpr, #"\b(okay|ok|alright|all right|fine|safe)\s+to\s+(stop|rest|pause|quit)\b"#),
        (.stopCpr, #"\b(stop|quit)\s+now\b"#),
        (.stopCpr, #"\b(don't|do not|doesn't|no need to|needn't)\s+(have to\s+|need to\s+)?(keep|continue)\b"#),
        (.dose, #"\b\d+(\.\d+)?\s?(mg|mcg|milligrams?|micrograms?|ml|milliliters?|units?)\b"#),
        (.dose, #"\b(aspirin|nitroglycerin|nitro|epinephrine|epipen|naloxone|narcan|ibuprofen|acetaminophen|tylenol|insulin|atropine|amiodarone|albuterol|inhaler)\b"#),
        (.deathStatement, "\\b\(subject)\\b[^.?!]{0,20}\\b(is|are|'s|'re)\\s+(dead|gone|deceased)\\b"),
        (.deathStatement, "\\b\(subject)\\b[^.?!]{0,20}\\b(died|passed away|passed on)\\b"),
        (.deathStatement, #"\b(didn't|did not|won't|will not|isn't going to|not going to)\s+make it\b"#),
        (.deathStatement, #"\b(too late|no point|no use)\b"#),
        (.reassurance, "\\b\(subject)('s|'re|\\s+is|\\s+are|\\s+seems?|\\s+looks?|\\s+sounds?|'ll be|\\s+will be)\\s+(going to be\\s+)?\(okay)\\b"),
        (.reassurance, "\\b\(subject)('s|'re|\\s+is|\\s+are)\\s+breathing\\s+(normally|fine|okay|ok)\\b"),
        (.reassurance, "\\b(everything|everyone|it)('s|\\s+is|'ll be|\\s+will be)\\s+(going to be\\s+)?\(okay)\\b"),
        (.reassurance, #"\bsounds?\s+(fine|okay|ok|normal)\b"#),
        (.reassurance, #"\b(no need|don't need|do not need|doesn't need)\b[^.?!]{0,25}\b(cpr|911|ems|call|compressions?)\b"#),
    ]

    private static let negations = ["don't", "do not", "never", "shouldn't", "should not", "must not", "no need to", "without"]

    private static let condition = #"(heart attack|cardiac arrest|stroke|seizure|fracture|broken bone|break|sprain|dislocation|concussion|panic attack)"#
    private static let sure = #"((definitely|certainly|clearly|obviously|surely|absolutely|just|not)\s+)*"#
    private static let clinician = #"(doctor|physician|nurse|paramedic|emt|surgeon|clinician|medic|medical professional|doc)"#
    private static let emergencyCare = #"(911|an ambulance|the ambulance|ems|emergency services)"#
    private static let hospital = #"(the\s+)?(er|hospital|emergency room|urgent care)"#
    private static let number = #"(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|half)"#

    /// Deliberately short, by choice for the demo: only lines that are wrong however they're put.
    /// Naming aspirin and telling someone to rest are ordinary here, and anything subtler is let through.
    private static let awakeRules: [(SentinelFlag.Category, String)] = [
        // "The paramedics will check his pulse" says what they'll do.
        (.pulseCheck, #"(?<!(ems|paramedics|they|they'll|will) )\b(check|checking|feel|feeling|find|look for|take)\b[^.?!]{0,30}\bpulse\b"#),
        (.dose, #"\b(\d+(\.\d+)?|\#(number)([\s-]+(and\s+)?\#(number))*)\s?(mg|mcg|milligrams?|micrograms?|ml|milliliters?)\b"#),
        // A count needs a verb to be a dose: "Tell the dispatcher he's had one aspirin" isn't one.
        (.dose, #"\b(give|take|chew|swallow|have)\b[^.?!,;]{0,16}\b(\d+|\#(number))[\s-]+([\w-]+\s+)?(pills?|tablets?|capsules?|aspirins?)\b"#),
        // The awake voice sounds like an emergency physician, so "I'm an emergency room doctor" and
        // "As an ER doctor, I'd..." are the slips to expect. "As a paramedic would" says what they'd do.
        (.identity, #"\b(i'm|i am)\s+(an?|your)\s+(\w+\s+){0,2}\#(clinician)\b"#),
        (.identity, #"\bas\s+your\s+(\w+\s+)?\#(clinician)\b"#),
        (.identity, #"\bas\s+an?\s+(\w+\s+){0,2}\#(clinician)\s*,?\s+(i|i'd|i'm|i'll|i've|my)\b"#),
        (.identity, #"\b(speaking|talking)\s+as\s+an?\s+(\w+\s+){0,2}\#(clinician)\b"#),
        (.discourageEmergency, #"\bno\s+need\s+to\s+(call|dial)\s+(\#(emergencyCare)|for help|anyone)\b"#),
        (.discourageEmergency, #"\b(you|he|she|they)\s+(don't|do not|doesn't|does not)\s+need\s+(to\s+call\s+)?(\#(emergencyCare)|paramedics)\b"#),
        (.discourageEmergency, #"\b(don't|do not)\s+(call|dial)\s+\#(emergencyCare)\b"#),
        (.discourageEmergency, #"\bwait\s+(and|to)\s+see\s+(a|your|his|her|their|the)\s+(doctor|gp)\b"#),
        (.selfTransport, #"\bdrive\s+(yourself|himself|herself|themselves)\b"#),
        // "Let EMS drive him to the hospital" is the plan going right.
        (.selfTransport, #"(?<!(ems|paramedics|ambulance|they|them) )\bdrive\s+(him|her|them|the patient)\s+to\s+\#(hospital)\b"#),
        (.selfTransport, #"\b(take|bring)\s+(him|her|them|the patient)\s+to\s+\#(hospital)\s+yourself\b"#),
        (.straighten, #"\bstraighten\s+(it|that|the|his|her|their|your)\b"#),
        (.straighten, #"\bpull\s+(it|that|(the|his|her|their|your)\s+\w+)\s+straight\b"#),
        (.straighten, #"\b(set|reset)\s+(the|that|his|her|their|your|a)\s+(bone|fracture|break)\b"#),
        (.selfCalling, #"\b(i'll|i will|i'm|i am|i've|i have|let me)\s+((now|just|already|going to)\s+)*(call|calling|called|dial|dialing|dialed|phone|phoning|phoned)\s+(for\s+)?(\#(emergencyCare)|help)\b"#),
        (.diagnosis, #"\b(he|she|they|you|the patient|the person)('s|'re|\s+is|\s+are)\s+\#(sure)having\s+an?\s+\#(condition)\b"#),
        (.diagnosis, #"\b(it|that|this)('s|\s+is|\s+isn't)\s+\#(sure)an?\s+\#(condition)\b"#),
    ]

    /// "It's not safe to drive him to the hospital yourself" tells them not to, and so do "safer to wait
    /// than to drive him" and "trying to straighten it could make it worse".
    private static let awakeNegations = negations + ["not to", "not safe", "avoid", "can't", "cannot", "than ", "instead of ", "trying to "]
    /// These don't reverse a line, but they stop it being an instruction or a statement of fact, and so
    /// does saying what someone else said.
    private static let awakeHedges = [
        "could ", "might ", "may ", "maybe ", "perhaps ", "possibly ", "if ", "whether ", "in case ", "not sure",
        "assume ", "treat it ", "says ", "said ", "thinks ",
    ]
    /// Asking what already happened tells nobody to do anything.
    private static let questions = ["did ", "does ", "has "]

    public static func check(_ text: String, profile: ValidatorProfile = .arrest) -> [SentinelFlag] {
        let normalized = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let whole = NSRange(normalized.startIndex..., in: normalized)
        var flags: [SentinelFlag] = []

        for (category, pattern) in profile == .arrest ? rules : awakeRules {
            guard !flags.contains(where: { $0.category == category }),
                  let regex = try? NSRegularExpression(pattern: pattern)
            else { continue }

            for match in regex.matches(in: normalized, range: whole) {
                guard let range = Range(match.range, in: normalized) else { continue }
                // "Do not stop compressions" is the correct advice, except for reassurance rules,
                // where the negation is the problem itself.
                if category != .reassurance, isCanceled(normalized, before: range, in: profile) { continue }
                flags.append(SentinelFlag(category: category, excerpt: String(normalized[range])))
                break
            }
        }
        return flags
    }

    private static func isCanceled(_ text: String, before range: Range<String.Index>, in profile: ValidatorProfile) -> Bool {
        let prefix = text[text.startIndex..<range.lowerBound]
        // Only its own clause counts: "Don't worry, stop compressions" negates nothing.
        let clause = prefix.split(omittingEmptySubsequences: false, whereSeparator: { ".?!,;:".contains($0) }).last.map(String.init) ?? ""
        guard profile == .awake else {
            let tail = String(clause.suffix(24))
            return negations.contains { tail.contains($0) }
        }
        // Awake lines run longer, and a word that takes one back still does from the far end of it.
        let own = afterLastBreak(in: clause)
        if questions.contains(where: { own.drop(while: \.isWhitespace).hasPrefix($0) }) { return true }
        return (awakeNegations + awakeHedges).contains { own.contains($0) }
    }

    /// "Don't move it because it's a fracture" advises one thing and states another as fact.
    private static func afterLastBreak(in clause: String) -> String {
        let padded = " \(clause)"
        let end = [" because ", " since ", " but ", " so "].compactMap { padded.range(of: $0, options: .backwards)?.upperBound }.max()
        return end.map { String(padded[$0...]) } ?? clause
    }
}

/// Collects streaming transcript text for one model turn and reports each category once.
public struct TranscriptBuffer: Sendable {
    private var text = ""
    private var seen: Set<SentinelFlag.Category> = []
    private var profile = ValidatorProfile.arrest

    public init() {}

    public mutating func feed(_ delta: String, profile: ValidatorProfile = .arrest) -> [SentinelFlag] {
        text += delta
        self.profile = profile
        guard profile == .awake else { return fresh(in: text) }
        // A flag can't be taken back, and "Give them two pill" might yet become "pillows".
        let settled = text.lastIndex { $0.isWhitespace || $0.isPunctuation }.map { String(text[...$0]) } ?? ""
        return fresh(in: settled)
    }

    /// Whatever only the last word could tell, now that it's known to be whole.
    @discardableResult
    public mutating func endTurn() -> [SentinelFlag] {
        let last = fresh(in: text)
        text = ""
        seen = []
        return last
    }

    private mutating func fresh(in text: String) -> [SentinelFlag] {
        let flags = TranscriptValidator.check(text, profile: profile).filter { !seen.contains($0.category) }
        seen.formUnion(flags.map(\.category))
        return flags
    }
}
