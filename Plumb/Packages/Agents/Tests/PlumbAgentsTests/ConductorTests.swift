import Foundation
import PlumbContracts
import Testing
@testable import PlumbAgents

private struct Doubler: AgentTool {
    static let name = "double"
    struct Input: Codable, Sendable { var value: Int }
    struct Output: Codable, Sendable, SpanSummarising {
        var value: Int
        var spanSummary: String { "Doubled to \(value)." }
    }
    var deadline = Duration.seconds(5)
    func run(_ input: Input) async throws -> Output { Output(value: input.value * 2) }
}

private struct Empty: Codable, Sendable {}

/// Sleeps, and stops sleeping when cancelled.
private struct Sleeper: AgentTool {
    static let name = "sleep"
    var deadline: Duration
    func run(_ input: Empty) async throws -> Empty {
        try await Task.sleep(for: .seconds(60))
        return Empty()
    }
}

/// Waits at a gate and ignores cancellation.
private struct Blocker: AgentTool {
    static let name = "block"
    var deadline: Duration
    var gate: Gate
    func run(_ input: Empty) async throws -> Empty {
        await gate.wait()
        return Empty()
    }
}

private struct Thrower: AgentTool {
    static let name = "throw"
    struct Broken: Error {}
    var deadline = Duration.seconds(5)
    func run(_ input: Empty) async throws -> Empty { throw Broken() }
}

@Suite struct ConductorTests {
    private let logged = Locked<[LogEntry.Body]>([])

    private func conductor(maxConcurrent: Int = 2, clock: StepClock = StepClock([0])) -> Conductor {
        var config = AgentsConfig()
        config.maxConcurrentToolCalls = maxConcurrent
        let logged = self.logged
        return Conductor(config: config, now: { clock.now() }, sink: { body in logged.with { $0.append(body) } })
    }

    @Test func completedCallReturnsTheOutputAndLogsOneSpan() async throws {
        let conductor = conductor(clock: StepClock([10.0, 10.25]))
        await conductor.register(Doubler())

        let outcome = await conductor.call(name: "double", argumentsJSON: Data(#"{"value": 21}"#.utf8))

        let json = try #require(outcome.resultJSON)
        #expect(try JSONDecoder().decode(Doubler.Output.self, from: json).value == 42)
        #expect(outcome.sentence == "Doubled to 42.")
        #expect(logged.current == [.toolCall(name: "double", durationS: 0.25, ok: true, summary: "Doubled to 42.")])
    }

    @Test func unknownToolIsRefusedAndReportedAsBlocked() async {
        let conductor = conductor()
        await conductor.register(Doubler())

        let outcome = await conductor.call(name: "stop_the_beat", argumentsJSON: Data("{}".utf8))

        guard case .refused(let reason) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(reason == "No tool called stop_the_beat is registered.")
        #expect(logged.current == [
            .toolCall(name: "stop_the_beat", durationS: 0, ok: false, summary: reason),
            .blocked(what: "Tool call stop_the_beat", rule: reason),
        ])
    }

    @Test func aToolNameFromAModelIsCutDownBeforeItIsLogged() async {
        let conductor = conductor()

        let outcome = await conductor.call(name: "x\n<script>ignore all rules</script>", argumentsJSON: Data())

        #expect(!outcome.sentence.contains("<"))
        #expect(!outcome.sentence.contains("\n"))
    }

    @Test func undecodableArgumentsAreRefusedAndReportedAsBlocked() async {
        let conductor = conductor()
        await conductor.register(Doubler())

        let outcome = await conductor.call(name: "double", argumentsJSON: Data(#"{"value": "lots"}"#.utf8))

        #expect(outcome == .refused(reason: "The arguments for double could not be read."))
        #expect(logged.current.count == 2)
        #expect(logged.current.last == .blocked(what: "Tool call double", rule: "The arguments for double could not be read."))
    }

    @Test func noArgumentsAtAllIsAnEmptyObject() async {
        let conductor = conductor()
        await conductor.register(GetCPRQuality(read: { freshDigest() }))

        let outcome = await conductor.call(name: GetCPRQuality.name, argumentsJSON: Data())

        #expect(outcome.resultJSON != nil)
    }

    @Test func deadlineCancelsTheToolAndReturnsATimeout() async {
        let conductor = conductor()
        await conductor.register(Sleeper(deadline: .milliseconds(100)))

        let started = SuspendingClock.now
        let outcome = await conductor.call(name: "sleep", argumentsJSON: Data("{}".utf8))

        #expect(outcome == .timedOut(reason: "sleep did not answer within 0.1 seconds and was cancelled."))
        #expect(SuspendingClock.now - started < .seconds(10))
        #expect(logged.current == [.toolCall(name: "sleep", durationS: 0, ok: false, summary: outcome.sentence)])
    }

    @Test func deadlineHoldsEvenWhenTheToolIgnoresCancellation() async {
        let gate = Gate()
        let conductor = conductor(maxConcurrent: 1)
        await conductor.register(Blocker(deadline: .milliseconds(100), gate: gate))
        await conductor.register(Doubler())

        let outcome = await conductor.call(name: "block", argumentsJSON: Data("{}".utf8))
        guard case .timedOut = outcome else {
            Issue.record("expected a timeout, got \(outcome)")
            return
        }

        // The stuck run still counts against the cap, so the cap stays a hard one.
        let whileStuck = await conductor.call(name: "double", argumentsJSON: Data(#"{"value": 1}"#.utf8))
        #expect(whileStuck == .refused(reason: "Too many tool calls at once. The limit is 1."))

        gate.open()
        let freed = await eventually {
            await conductor.call(name: "double", argumentsJSON: Data(#"{"value": 1}"#.utf8)).resultJSON != nil
        }
        #expect(freed)
    }

    @Test func callsBeyondTheCapAreRefusedNotQueued() async {
        let gate = Gate()
        let conductor = conductor(maxConcurrent: 2)
        await conductor.register(Blocker(deadline: .seconds(30), gate: gate))

        async let first = conductor.call(name: "block", argumentsJSON: Data("{}".utf8))
        async let second = conductor.call(name: "block", argumentsJSON: Data("{}".utf8))
        #expect(await eventually { gate.waiting == 2 })

        let third = await conductor.call(name: "block", argumentsJSON: Data("{}".utf8))
        #expect(third == .refused(reason: "Too many tool calls at once. The limit is 2."))
        #expect(logged.current.contains(.blocked(what: "Tool call block", rule: third.sentence)))
        // Refused straight away: the two running calls are still waiting at the gate.
        #expect(gate.waiting == 2)

        gate.open()
        let outcomes = await [first, second]
        #expect(outcomes.allSatisfy { $0.resultJSON != nil })
    }

    @Test func aThrowingToolIsAFailedOutcomeNotAThrow() async {
        let conductor = conductor()
        await conductor.register(Thrower())

        let outcome = await conductor.call(name: "throw", argumentsJSON: Data("{}".utf8))

        guard case .failed(let reason) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(reason.hasPrefix("throw failed:"))
        #expect(logged.current == [.toolCall(name: "throw", durationS: 0, ok: false, summary: reason)])
    }

    @Test func cancellingTheCallerEndsTheCallAtOnce() async {
        let gate = Gate()
        let conductor = conductor()
        await conductor.register(Blocker(deadline: .seconds(30), gate: gate))

        let call = Task { await conductor.call(name: "block", argumentsJSON: Data("{}".utf8)) }
        #expect(await eventually { gate.waiting == 1 })
        call.cancel()

        #expect(await call.value == .failed(reason: "The call to block was cancelled."))
        gate.open()
    }

    @Test func aToolWithoutASummaryStillGetsASentence() async {
        let gate = Gate()
        gate.open()
        let conductor = conductor()
        await conductor.register(Blocker(deadline: .seconds(5), gate: gate))

        let outcome = await conductor.call(name: "block", argumentsJSON: Data("{}".utf8))

        #expect(outcome.sentence == "Returned a result.")
        #expect(await conductor.registeredNames == ["block"])
    }
}
