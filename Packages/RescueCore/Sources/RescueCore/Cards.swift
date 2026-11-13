import Foundation

private let notRecorded = "not recorded"

func clock(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "T+%d:%02d", total / 60, total % 60)
}

struct LogFacts {
    let startedAt: TimeInterval
    let entries: [LogEntry]

    init(_ entries: [LogEntry]) {
        self.entries = entries
        startedAt = entries.first?.at ?? 0
    }

    func first(_ kind: LogEntry.Kind) -> LogEntry? { entries.first { $0.kind == kind } }
    func all(_ kind: LogEntry.Kind) -> [LogEntry] { entries.filter { $0.kind == kind } }

    func last(_ kind: LogEntry.Kind) -> LogEntry? { entries.last { $0.kind == kind } }

    /// Latest answer for a question.
    func answer(_ question: String) -> LogEntry? {
        entries.last { $0.kind == .answer && $0.detail.hasPrefix("\(question)=") }
    }

    /// The latest word on a question, from answers and AI findings, whichever came last.
    private func latest(_ question: String, findings: Set<String>) -> LogEntry? {
        entries.last {
            ($0.kind == .answer && $0.detail.hasPrefix("\(question)=")) || ($0.kind == .finding && findings.contains($0.detail))
        }
    }

    func latestResponsive() -> LogEntry? { latest("responsive", findings: ["unresponsive"]) }
    func latestBreathing() -> LogEntry? { latest("breathing", findings: ["abnormal_breathing", "not_breathing"]) }

    func time(_ entry: LogEntry?) -> String {
        entry.map { clock($0.at - startedAt) } ?? notRecorded
    }

    /// The latest flow, and whether it still stands. Going back to triage takes it back.
    func concern() -> (entry: LogEntry, stands: Bool)? {
        guard let entry = last(.flowEntered) else { return nil }
        let wentBack = entries.contains {
            $0.kind == .stateEntered && $0.detail == ScenarioModule.triageState && $0.seq > entry.seq
        }
        return (entry, !wentBack)
    }

    /// An id as words. A flow id must start with `possible_`, so its name can't state a condition as fact.
    static func words(_ id: String) -> String {
        id.replacingOccurrences(of: "_", with: " ")
    }

    /// What moved the rescue into this flow and along it, oldest first. A report that moved something
    /// logs its finding right before its observation, and one that only went on the record has no finding.
    func reports(behind flow: LogEntry) -> [LogEntry] {
        let moved = zip(entries, entries.dropFirst()).compactMap { $0.kind == .finding && $1.kind == .observation ? $1 : nil }
        let routed = flow.source == .aiInferred ? entries.last { $0.seq < flow.seq && $0.kind == .observation } : nil
        return [routed].compactMap { $0 } + moved.filter { $0.seq > flow.seq }
    }

    /// "AI heard" and "chest pain (high)", from an observation's `kind,source,confidence`.
    static func observed(_ entry: LogEntry) -> (label: String, value: String)? {
        let parts = entry.detail.split(separator: ",").map(String.init)
        guard parts.count == 3 else { return nil }
        let label = parts[1] == ObservationSource.seen.rawValue ? "AI saw" : "AI heard"
        return (label, "\(words(parts[0])) (\(parts[2]))")
    }

    static func reported(_ entry: LogEntry) -> String? {
        entry.detail.split(separator: ",").first.map { words(String($0)) }
    }
}

public struct HandoffCard: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public var label: String
        public var value: String
        /// Nil when nothing was recorded.
        public var source: EvidenceSource?
        /// When an answer was given, since a later event can overtake it.
        public var time: String?
    }

    public var items: [Item]
    public var timeline: [Item]
    public var readout: String
}

/// Builds the EMS card from the event log, never from transcripts. It says "not recorded" rather
/// than zero, since hands-busy rescuers miss taps, and "coaching started" rather than "CPR started",
/// since the app can't see that CPR began.
public enum HandoffBuilder {
    public static func build(from entries: [LogEntry]) -> HandoffCard {
        let facts = LogFacts(entries)
        let shocks = facts.all(.shockMarked)
        // Only what never happened hides, so a patient who went on to need CPR keeps every row.
        let showsArrest = facts.concern() == nil || facts.first(.coachingStarted) != nil

        var items: [HandoffCard.Item] = []
        func add(_ label: String, _ entry: LogEntry?) {
            items.append(.init(label: label, value: facts.time(entry), source: entry?.source))
        }

        if let row = concernRow(facts) { items.append(row) }
        let responsive = evidence(facts.latestResponsive(), facts)
        let breathing = evidence(facts.latestBreathing(), facts)
        items.append(.init(label: "Responding", value: responsive.value, source: responsive.source, time: responsive.time))
        items.append(.init(label: "Breathing normally", value: breathing.value, source: breathing.source, time: breathing.time))
        if showsArrest { add("Coaching started", facts.first(.coachingStarted)) }
        add("911 prompted", facts.first(.callPrompted))
        if showsArrest {
            add("AED arrived", facts.first(.aedArrived))
            add("Pads on", facts.first(.padsOn))
            items.append(.init(
                label: "Shocks marked",
                value: shocks.isEmpty ? notRecorded : String(shocks.count),
                source: shocks.first?.source
            ))
        }
        if showsArrest || facts.first(.patientMoved) != nil { add("Patient moved", facts.first(.patientMoved)) }
        if facts.concern() != nil {
            items += answerRows(facts)
            for aspirin in facts.all(.aspirinAdvised) { add(aspirinLine, aspirin) }
            items += observationRows(facts)
        }

        return HandoffCard(items: items, timeline: timeline(facts), readout: readout(facts, responsive: responsive.spoken, breathing: breathing.spoken, shocks: shocks.count, showsArrest: showsArrest))
    }

    // The app can say it was advised. Nothing here can see whether it was taken.
    private static let aspirinLine = "Aspirin advised, not confirmed taken"
    private static let arrestQuestions: Set<String> = ["responsive", "breathing", "adult"]

    private static func concernRow(_ facts: LogFacts) -> HandoffCard.Item? {
        guard let concern = facts.concern() else { return nil }
        let opening = capitalized(LogFacts.words(concern.entry.detail))
        let value = concern.stands ? "\(opening). Not a diagnosis." : "\(opening) earlier, not confirmed since. Not a diagnosis."
        return .init(label: "Concern", value: value, source: concern.entry.source, time: facts.time(concern.entry))
    }

    /// The latest answer to each question the rows above don't already cover.
    private static func answerRows(_ facts: LogFacts) -> [HandoffCard.Item] {
        var questions: [String] = []
        for entry in facts.all(.answer) {
            let question = String(entry.detail.prefix { $0 != "=" })
            if !arrestQuestions.contains(question), !questions.contains(question) { questions.append(question) }
        }
        return questions.compactMap { question in
            facts.answer(question).map { entry in
                .init(label: capitalized(LogFacts.words(question)), value: answerText(entry), source: entry.source, time: facts.time(entry))
            }
        }
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// One row per distinct report, or a model that keeps saying so would push everything else off.
    private static func observationRows(_ facts: LogFacts) -> [HandoffCard.Item] {
        var seen: Set<String> = []
        return facts.all(.observation).compactMap { entry in
            guard seen.insert(entry.detail).inserted, let observed = LogFacts.observed(entry) else { return nil }
            return .init(label: observed.label, value: observed.value, source: entry.source, time: facts.time(entry))
        }
    }

    private struct Evidence {
        var value: String
        var source: EvidenceSource?
        var time: String?
        var spoken: String { time.map { "\(value) at \($0)" } ?? value }
    }

    private static func evidence(_ entry: LogEntry?, _ facts: LogFacts) -> Evidence {
        guard let entry else { return Evidence(value: notRecorded) }
        return Evidence(value: answerText(entry), source: entry.source, time: facts.time(entry))
    }

    /// Findings only ever say no, because the gate rejects any report that would lower urgency.
    static func answerText(_ entry: LogEntry) -> String {
        if entry.kind == .finding { return entry.detail == "abnormal_breathing" ? "no, abnormal" : "no" }
        switch entry.detail.split(separator: "=").last.map(String.init) {
        case "yes": return "yes"
        case "no": return "no"
        case "unsure": return "unsure"
        case "no_breaths_marked": return "no breaths marked"
        default: return "no reply"
        }
    }

    private static func timeline(_ facts: LogFacts) -> [HandoffCard.Item] {
        let labels: [LogEntry.Kind: String] = [
            .sessionStarted: "App opened",
            .callPrompted: "911 prompted",
            .coachingStarted: "Coaching started",
            .aedArrived: "AED arrived",
            .padsOn: "Pads on",
            .shockMarked: "Shock marked",
            .patientMoved: "Patient moved",
            .emsArrived: "EMS arrived",
            .aspirinAdvised: aspirinLine,
        ]
        // Re-entering a state logs its kind again, but only these can really repeat. A flow is only
        // logged when it changes, and which one it was matters.
        let repeatable: Set<LogEntry.Kind> = [.shockMarked, .patientMoved, .flowEntered, .aspirinAdvised]
        var seen: Set<LogEntry.Kind> = []
        return facts.entries.compactMap { entry in
            guard let label = entry.kind == .flowEntered ? "Concern: \(LogFacts.words(entry.detail))" : labels[entry.kind] else { return nil }
            guard repeatable.contains(entry.kind) || seen.insert(entry.kind).inserted else { return nil }
            return .init(label: label, value: clock(entry.at - facts.startedAt), source: entry.source)
        }
    }

    private static func readout(_ facts: LogFacts, responsive: String, breathing: String, shocks: Int, showsArrest: Bool) -> String {
        var lines = ["Simulation handoff, generated by an app and not verified."]
        if let concern = facts.concern() {
            let earlier = concern.stands ? "" : " earlier"
            lines.append("Concern: \(LogFacts.words(concern.entry.detail))\(earlier), not a diagnosis.")
        }
        lines.append("Responding: \(responsive).")
        lines.append("Breathing normally: \(breathing).")
        let advised = facts.all(.aspirinAdvised)
        if !advised.isEmpty { lines.append("\(aspirinLine), at \(advised.map(facts.time).joined(separator: " and ")).") }
        if showsArrest {
            lines.append("Coaching started: \(facts.time(facts.first(.coachingStarted))).")
            lines.append("Pads on: \(facts.time(facts.first(.padsOn))).")
            lines.append("Shocks marked: \(shocks == 0 ? notRecorded : String(shocks)).")
        }
        return lines.joined(separator: " ")
    }
}

public struct CallerLocation: Sendable, Equatable {
    public var address: String?
    public var accuracyMeters: Double?
    /// True only after the caller confirms it. An unconfirmed address is never spoken.
    public var confirmed: Bool

    public init(address: String?, accuracyMeters: Double?, confirmed: Bool) {
        self.address = address
        self.accuracyMeters = accuracyMeters
        self.confirmed = confirmed
    }
}

public struct CallerScript: Sendable, Equatable {
    public var locationLine: String
    public var situation: String
    public var actions: [String]
    public var resources: [String]
    public var readAloud: String
}

public enum CallerScriptBuilder {
    public static func build(from entries: [LogEntry], location: CallerLocation?, resources: Set<Resource>) -> CallerScript {
        let facts = LogFacts(entries)
        let resourceNames = resources.map(\.rawValue).sorted().map { raw in
            let name = raw.replacingOccurrences(of: "_", with: " ")
            let seen = entries.last { $0.kind == .resourceSeen && $0.detail == raw }
            return seen?.source == .aiInferred ? "\(name) (AI-inferred)" : name
        }

        var actions: [String] = []
        if facts.first(.coachingStarted) != nil { actions.append("CPR coaching started") }
        if facts.first(.aedArrived) != nil { actions.append("AED on scene") }
        if facts.first(.padsOn) != nil { actions.append("AED pads on") }
        let situation = situationLine(facts)

        var spoken = ["I am an AI assistant speaking for the caller. This is a simulation.", situation]
        if !actions.isEmpty { spoken.append(actions.joined(separator: ", ") + ".") }
        if let address = location?.address, location?.confirmed == true {
            spoken.append("The address is \(address).")
        } else {
            spoken.append("The caller will confirm the location.")
        }

        return CallerScript(
            locationLine: locationLine(location),
            situation: situation,
            actions: actions,
            resources: resourceNames,
            readAloud: spoken.joined(separator: " ")
        )
    }

    /// The lines above already say these.
    private static let collapses: Set<String> = ["unresponsive", "not breathing", "abnormal breathing"]

    /// Says only what the log supports. An answer that coaching has since overtaken is reported as
    /// earlier, and a missing or unsure one is never read as a fact.
    private static func situationLine(_ facts: LogFacts) -> String {
        let special = facts.answer("adult")?.detail == "adult=no"
        let coaching = facts.last(.coachingStarted)
        func overtaken(_ entry: LogEntry) -> Bool { coaching.map { $0.seq > entry.seq } ?? false }

        var line = special ? "Child, infant, drowning, or pregnant patient" : "Adult"
        if let responsive = facts.latestResponsive() {
            switch HandoffBuilder.answerText(responsive) {
            case "yes":
                line += overtaken(responsive) ? ", responded earlier, not confirmed since" : " unwell, responding"
            case "no":
                line += " collapsed, not responding"
            default:
                line += ", responsiveness not confirmed"
            }
        } else {
            line += ", responsiveness not recorded"
        }
        if let breathing = facts.latestBreathing() {
            switch HandoffBuilder.answerText(breathing) {
            case "yes":
                line += overtaken(breathing) ? ", breathing reported earlier, not confirmed since" : ", breathing reported"
            case "no", "no, abnormal":
                line += ", not breathing normally"
            default:
                line += ", breathing not confirmed"
            }
        }
        if let concern = facts.concern(), concern.stands {
            line += ", \(LogFacts.words(concern.entry.detail))"
            // "Possible broken bone" alone would hide bleeding or a neck injury from the dispatcher.
            let heard = facts.reports(behind: concern.entry).compactMap(LogFacts.reported).filter { !collapses.contains($0) }
            let distinct = heard.enumerated().filter { !heard[..<$0.offset].contains($0.element) }.map(\.element)
            if !distinct.isEmpty { line += ", AI reported \(distinct.joined(separator: ", "))" }
        }
        return line + "."
    }

    private static func locationLine(_ location: CallerLocation?) -> String {
        guard let location, let address = location.address else {
            return "Location unknown. Give any address you know."
        }
        if location.confirmed { return address }
        let radius = location.accuracyMeters.map { " within about \(Int($0)) m" } ?? ""
        return "Approximate, confirm: \(address)\(radius). Give any address you know first."
    }
}
