import Foundation

/// How one tool call ended. Failure is a value here, never a thrown error, so a model's bad request
/// can never take the caller down with it.
public enum ToolOutcome: Sendable, Equatable {
    /// The tool ran and returned. `resultJSON` is its output; `summary` is one sentence about it.
    case completed(resultJSON: Data, summary: String)
    /// The call never ran: no such tool, unreadable arguments, or too many calls at once.
    case refused(reason: String)
    /// The tool ran past its deadline and was cancelled.
    case timedOut(reason: String)
    /// The tool threw, or the caller cancelled the call.
    case failed(reason: String)

    /// The tool's output, or nil when the call did not complete.
    public var resultJSON: Data? {
        if case .completed(let json, _) = self { return json }
        return nil
    }

    /// One plain sentence about how the call ended.
    public var sentence: String {
        switch self {
        case .completed(_, let summary): return summary
        case .refused(let reason), .timedOut(let reason), .failed(let reason): return reason
        }
    }
}
