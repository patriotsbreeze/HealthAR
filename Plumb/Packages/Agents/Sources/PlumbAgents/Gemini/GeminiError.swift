import Foundation

/// Why a call to the model service failed.
///
/// Every piece of outside text carried here has already had the API key removed and been cut to a
/// short prefix, so an error can be logged or shown as it is.
public enum GeminiError: Error, Equatable, Sendable {
    /// The request could not be put together.
    case unbuildable
    /// The network call itself failed, twice.
    case transport(detail: String)
    /// The service answered with an error status.
    case http(status: Int, detail: String)
    /// No answer arrived within the budget.
    case timedOut(seconds: Double)
    /// The caller cancelled the call.
    case cancelled
    /// The service answered, but not in a shape this client understands.
    case unreadable
    /// The service answered without any text from the model.
    case noText(detail: String)
}

extension GeminiError: CustomStringConvertible, LocalizedError {
    /// One plain sentence. Never contains the API key.
    public var description: String {
        switch self {
        case .unbuildable:
            return "The request could not be built."
        case .transport(let detail):
            return "The network call failed: \(detail)"
        case .http(let status, let detail):
            return "The service answered with HTTP \(status): \(detail)"
        case .timedOut(let seconds):
            return "The service did not answer within \(seconds.oneDecimal) seconds."
        case .cancelled:
            return "The call was cancelled."
        case .unreadable:
            return "The service's answer could not be read."
        case .noText(let detail):
            return "The model returned no text: \(detail)"
        }
    }

    /// The same sentence, for code that asks for `localizedDescription`.
    public var errorDescription: String? { description }
}
