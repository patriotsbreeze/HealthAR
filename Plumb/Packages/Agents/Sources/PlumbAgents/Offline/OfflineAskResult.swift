import Foundation
import PlumbContracts

/// One question asked with no network: what was heard, how it was read, and the fixed sentence said back.
public struct OfflineAskResult: Sendable, Equatable {
    /// What the person said, as transcribed on the phone. Nil when nothing was heard.
    public var heard: String?
    public var intent: AskIntent
    /// The fixed sentence to say aloud and to show as the caption.
    public var answer: String
    /// What read the question. Nil when nothing was heard, so nothing was read.
    public var classifiedBy: IntentSource?
    /// Why the keyword rules read the question rather than the model, in plain words.
    public var fallbackReason: String?

    /// Creates a result.
    public init(heard: String?, intent: AskIntent, answer: String, classifiedBy: IntentSource?,
                fallbackReason: String? = nil) {
        self.heard = heard
        self.intent = intent
        self.answer = answer
        self.classifiedBy = classifiedBy
        self.fallbackReason = fallbackReason
    }

    /// The lines for the session log, in order: what was asked, how it was read, what was said back.
    /// The answer is a fixed template, so it is logged as decided by a rule, never by a model.
    public var logLines: [(source: LogEntry.Source, body: LogEntry.Body)] {
        var lines: [(source: LogEntry.Source, body: LogEntry.Body)] = []
        if let heard {
            lines.append((.said, .note("Asked: \(heard)")))
        }
        switch classifiedBy {
        case .model:
            lines.append((.model, .note("Read the question as \(intent.plainName), on this phone.")))
        case .keywords:
            let why = fallbackReason.map { " \($0)" } ?? ""
            lines.append((.rule, .note("Read the question as \(intent.plainName) from its words.\(why)")))
        case nil:
            break
        }
        lines.append((.rule, .note("Answered: \(answer)")))
        return lines
    }
}
