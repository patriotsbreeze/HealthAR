import Foundation

/// Why the screen shows this flow. Rebuilt from the log on every read, like the EMS card, and never
/// from a state field, so it can't go stale after a forced walk.
public struct FlowExplanation: Sendable, Equatable {
    public enum Chooser: String, Sendable, Equatable {
        case ai = "AI chose"
        case person = "You tapped"
        /// Stage control or a timer. Nobody's judgment, so it must not read as anyone's.
        case neither = "Set automatically"
    }

    public var headline: String
    public var chooser: Chooser
    /// The tap and report behind it, oldest first, each with its time.
    public var lines: [String]
    public var why: String
    public var source: String

    /// Nil unless the rescue is in a flow right now. A log with no flow entered is the plainest case,
    /// and the others are a person going back to triage and a collapse into the arrest path.
    public static func build(from entries: [LogEntry], bundle: ProtocolBundle) -> FlowExplanation? {
        let facts = LogFacts(entries)
        guard let entered = facts.last(.flowEntered),
              let flow = bundle.flows.first(where: { $0.id == entered.detail }),
              let current = facts.last(.stateEntered),
              bundle.definition.states.first(where: { $0.id == current.detail })?.flow == flow.id
        else { return nil }

        var lines: [String] = []
        if let awake = entries.last(where: { $0.seq < entered.seq && $0.kind == .answer && $0.detail == "responsive=yes" }) {
            lines.append("You tapped: patient is awake, \(facts.time(awake))")
        }

        let chooser: Chooser
        switch entered.source {
        case .aiInferred:
            chooser = .ai
        case .bystander:
            chooser = .person
            lines.append("You tapped: \(LogFacts.words(flow.id)), \(facts.time(entered))")
        case .timer, .sensor, .system:
            chooser = .neither
        }
        for report in facts.reports(behind: entered) {
            if let observed = LogFacts.observed(report) {
                lines.append("\(observed.label): \(observed.value), \(facts.time(report))")
            }
        }

        return FlowExplanation(
            headline: "\(flow.title). Not a diagnosis.",
            chooser: chooser,
            lines: lines,
            why: "Why: \(flow.rule.hasSuffix(".") ? flow.rule : flow.rule + ".")",
            source: "Source: \(flow.sources.joined(separator: "; ")). DRAFT."
        )
    }

    /// The latest report, if nothing has moved since it landed. One that moved the step logged before
    /// entering, so this only ever finds what went on the record and changed nothing.
    public static func note(from entries: [LogEntry]) -> String? {
        let facts = LogFacts(entries)
        guard let report = facts.last(.observation), let observed = LogFacts.observed(report),
              report.seq > facts.last(.stateEntered)?.seq ?? -1
        else { return nil }
        return "\(observed.label): \(observed.value). Nothing changed."
    }
}
