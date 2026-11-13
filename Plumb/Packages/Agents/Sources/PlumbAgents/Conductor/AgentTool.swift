import Foundation

/// Something a model may ask the app to do. A tool is ordinary code with typed input and output;
/// the Conductor is the only thing that runs one.
public protocol AgentTool: Sendable {
    /// The name a model uses to ask for this tool.
    static var name: String { get }
    /// What the model must send. Decoded from JSON before the tool runs.
    associatedtype Input: Codable & Sendable
    /// What the tool hands back. Encoded to JSON for the model.
    associatedtype Output: Codable & Sendable
    /// How long one run may take before it is cancelled.
    var deadline: Duration { get }
    /// Does the work.
    func run(_ input: Input) async throws -> Output
}

/// A tool output that can describe itself in one plain sentence for the session log.
public protocol SpanSummarising {
    /// One sentence a person can read in the log.
    var spanSummary: String { get }
}
