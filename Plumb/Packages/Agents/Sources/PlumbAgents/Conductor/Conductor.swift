import Foundation
import PlumbContracts

/// Runs tools on behalf of a model. It is plain scheduling code: it looks a tool up by name, checks
/// the arguments, enforces a deadline and a concurrency cap, and writes down what happened.
public actor Conductor {
    private let config: AgentsConfig
    private let now: @Sendable () -> TimeInterval
    private let sink: @Sendable (LogEntry.Body) -> Void
    private var tools: [String: RegisteredTool] = [:]
    /// Tool runs that have started and not yet truly ended, including ones cancelled at their deadline.
    private var running = 0

    /// - Parameters:
    ///   - now: the session clock, in seconds since the session started. Spans are timed with it.
    ///   - sink: receives one `.toolCall` for every call, and a `.blocked` as well for every refusal.
    public init(config: AgentsConfig = AgentsConfig(),
                now: @escaping @Sendable () -> TimeInterval,
                sink: @escaping @Sendable (LogEntry.Body) -> Void) {
        self.config = config
        self.now = now
        self.sink = sink
    }

    /// Makes a tool callable by its name. A second tool with the same name replaces the first.
    public func register<Tool: AgentTool>(_ tool: Tool) {
        tools[Tool.name] = RegisteredTool(tool)
    }

    /// The names of the tools that can be called, in alphabetical order.
    public var registeredNames: [String] {
        tools.keys.sorted()
    }

    /// Runs the named tool with JSON arguments and reports how it ended. Never throws.
    ///
    /// The call returns at the tool's deadline even if the tool ignores cancellation; such a run
    /// keeps its place under the concurrency cap until it really stops.
    public func call(name: String, argumentsJSON: Data) async -> ToolOutcome {
        let started = now()
        let shownName = Self.shown(name)
        guard let tool = tools[name] else {
            return refuse(shownName, started: started, reason: "No tool called \(shownName) is registered.")
        }
        // A model may send nothing at all for a tool that takes no arguments.
        let arguments = argumentsJSON.isEmpty ? Data("{}".utf8) : argumentsJSON
        guard let work = tool.prepare(arguments) else {
            return refuse(shownName, started: started, reason: "The arguments for \(shownName) could not be read.")
        }
        guard running < config.maxConcurrentToolCalls else {
            return refuse(shownName, started: started,
                          reason: "Too many tool calls at once. The limit is \(config.maxConcurrentToolCalls).")
        }

        running += 1
        let (events, feed) = AsyncStream<RaceEvent>.makeStream()
        let runner = Task {
            do {
                feed.yield(.finished(.success(try await work())))
            } catch {
                feed.yield(.finished(.failure(error)))
            }
        }
        let timer = Task {
            do {
                try await Task.sleep(for: tool.deadline)
                feed.yield(.deadline)
            } catch {
                // Cancelled because the tool finished first.
            }
        }
        let first = await withTaskCancellationHandler {
            await events.first { _ in true }
        } onCancel: {
            runner.cancel()
        }
        timer.cancel()
        feed.finish()

        let outcome: ToolOutcome
        switch first {
        case .finished(.success(let product)):
            running -= 1
            outcome = .completed(resultJSON: product.json, summary: product.summary)
        case .finished(.failure(let error)):
            running -= 1
            outcome = .failed(reason: "\(shownName) failed: \(Scrubber.flatten(String(describing: error), limit: 80))")
        case .deadline:
            abandon(runner)
            let limit = tool.deadline.inSeconds.oneDecimal
            outcome = .timedOut(reason: "\(shownName) did not answer within \(limit) seconds and was cancelled.")
        case nil:
            abandon(runner)
            outcome = .failed(reason: "The call to \(shownName) was cancelled.")
        }
        record(shownName, started: started, outcome: outcome)
        return outcome
    }

    // MARK: - Private

    private enum RaceEvent: Sendable {
        case finished(Result<ToolProduct, any Error>)
        case deadline
    }

    /// Cancels a run nobody is waiting for any more, and frees its slot only once it has really stopped.
    private func abandon(_ runner: Task<Void, Never>) {
        runner.cancel()
        Task {
            await runner.value
            running -= 1
        }
    }

    private func refuse(_ shownName: String, started: TimeInterval, reason: String) -> ToolOutcome {
        let outcome = ToolOutcome.refused(reason: reason)
        record(shownName, started: started, outcome: outcome)
        sink(.blocked(what: "Tool call \(shownName)", rule: reason))
        return outcome
    }

    private func record(_ shownName: String, started: TimeInterval, outcome: ToolOutcome) {
        let span = ToolSpan(name: shownName, startT: started, endT: now(),
                            ok: outcome.resultJSON != nil, summary: outcome.sentence)
        sink(span.logBody)
    }

    /// A tool name as it may appear in a log line. Names come from a model, so they are cut down first.
    private static func shown(_ name: String) -> String {
        let label = Scrubber.label(name)
        return label.isEmpty ? "an unnamed tool" : label
    }
}

/// One tool call as the log sees it.
struct ToolSpan: Sendable {
    var name: String
    var startT: TimeInterval
    var endT: TimeInterval
    var ok: Bool
    /// The tool's own summary when it worked, the failure in one sentence when it did not.
    var summary: String

    var logBody: LogEntry.Body {
        .toolCall(name: name, durationS: max(0, endT - startT), ok: ok, summary: summary)
    }
}

/// A tool's output, ready to hand to a model and to the log.
struct ToolProduct: Sendable {
    var json: Data
    var summary: String
}

/// A tool with its types erased, so tools of different shapes can share one table.
struct RegisteredTool: Sendable {
    let deadline: Duration
    /// Decodes the arguments and returns the work to run, or nil when the arguments do not decode.
    let prepare: @Sendable (Data) -> (@Sendable () async throws -> ToolProduct)?

    init<Tool: AgentTool>(_ tool: Tool) {
        deadline = tool.deadline
        prepare = { arguments in
            guard let input = try? JSONDecoder().decode(Tool.Input.self, from: arguments) else { return nil }
            return {
                let output = try await tool.run(input)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let summary = (output as? any SpanSummarising)?.spanSummary ?? "Returned a result."
                return ToolProduct(json: try encoder.encode(output), summary: summary)
            }
        }
    }
}
