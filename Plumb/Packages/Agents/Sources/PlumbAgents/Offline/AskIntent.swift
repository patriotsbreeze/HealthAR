import Foundation

/// What a spoken question asks about. A closed set: a question that fits none of these is `unknown`.
///
/// Reading a question only ever picks one of these. The words said back are fixed sentences chosen
/// for the intent by `OfflineAnswerer`, so whatever reads the question can never write the answer.
public enum AskIntent: String, Sendable, Codable, CaseIterable, Equatable {
    /// How it is going in general: rate and depth together, or the pause when there is one.
    case overall
    /// How fast the compressions are.
    case rate
    /// How deep the compressions are.
    case depth
    /// Whether compressions have stopped, and for how long.
    case pauses
    /// How many compressions so far.
    case count
    /// Anything else, including any question about a person's condition.
    case unknown

    /// The intent in plain words, for the session log.
    public var plainName: String {
        switch self {
        case .overall: "how it is going"
        case .rate: "rate"
        case .depth: "depth"
        case .pauses: "pauses"
        case .count: "count"
        case .unknown: "something it cannot answer"
        }
    }
}
