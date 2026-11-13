import Foundation
import Testing
@testable import RescueCore

func repoRoot(file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent() // RescueCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // RescueCore
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repo root
}

func loadBundle() throws -> ProtocolBundle {
    let clinical = repoRoot().appendingPathComponent("clinical")
    return try ProtocolBundle(
        protocolData: Data(contentsOf: clinical.appendingPathComponent("adult_arrest.v1.json")),
        phrasesData: Data(contentsOf: clinical.appendingPathComponent("phrases.v1.json"))
    )
}

/// Core, the shipped modules, and the pack. This is what the app runs.
func loadMergedBundle() throws -> ProtocolBundle {
    let clinical = repoRoot().appendingPathComponent("clinical")
    let modules = ScenarioModule.manifest.map { id in
        ModuleSource(id: id, data: try? Data(contentsOf: clinical.appendingPathComponent("modules/\(id).json")))
    }
    let pack = try? Data(contentsOf: clinical.appendingPathComponent("\(KnowledgePack.id).json"))
    return try loadBundle().merging(modules: modules, pack: pack)
}

/// Drives the engine and keeps the log, the way the app does.
struct Session {
    let engine: ProtocolEngine
    var state: RescueState
    var log = EventLog()
    var effects: [RescueEffect] = []
    /// Every phrase since the session began, unlike `phrases`, which is only the last event's.
    var allPhrases: [String] = []
    var now: TimeInterval

    init(engine: ProtocolEngine, at start: TimeInterval = 100) {
        self.engine = engine
        now = start
        let result = engine.start(at: start)
        state = result.state
        effects = result.effects
        log.append(result.log, at: start)
        allPhrases = phrases
    }

    mutating func send(_ event: RescueEvent) {
        let result = engine.reduce(state, event, at: now)
        state = result.state
        effects = result.effects
        log.append(result.log, at: now)
        allPhrases += phrases
    }

    mutating func human(_ action: HumanAction) { send(.human(action)) }

    mutating func advance(_ seconds: TimeInterval) {
        now += seconds
        send(.tick)
    }

    func proposal(_ action: ModelProposal.Action) -> ModelProposal {
        ModelProposal(action: action, stateVersion: state.version, issuedAt: now)
    }

    mutating func model(_ action: ModelProposal.Action) { send(.model(proposal(action))) }

    mutating func modelFinding(_ finding: Finding) {
        model(.reportFinding(finding, source: .heard, confidence: .high))
    }

    var phrases: [String] {
        effects.compactMap { if case let .playPhrase(id) = $0 { id } else { nil } }
    }

    /// Fast path to compressions through the real flow.
    mutating func goToCompressions() {
        human(.startCpr)
    }

    /// Compressions, then the real steps to the pads and AED analysis.
    mutating func goToAnalysis() {
        goToCompressions()
        human(.aedHere)
        human(.padsOn)
    }

    func entries(_ kind: LogEntry.Kind) -> [LogEntry] {
        log.entries.filter { $0.kind == kind }
    }
}

/// Deterministic generator, so fuzz failures reproduce.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
