import Foundation
import RescueCore

/// Where someone is in a run of steps. Only where there is a real sequence: the setup chain before
/// compressions has a known length, a flow branches so only its count so far is honest, and cards,
/// triage and CPR have no sequence to number.
struct StepProgress: Equatable {
    var index: Int
    var total: Int?

    var text: String { total.map { "Step \(index) of \($0)" } ?? "Step \(index)" }
}

enum StepProgressBuilder {
    static func build(engine: ProtocolEngine, entries: [LogEntry], stateID: String) -> StepProgress? {
        guard let current = engine.definition(of: stateID) else { return nil }
        switch current.kind {
        case .setup:
            // One straight chain, in file order. Start CPR leaves it, so nothing skips a number.
            let chain = engine.bundle.definition.states.filter { $0.kind == .setup }.map(\.id)
            guard let index = chain.firstIndex(of: stateID) else { return nil }
            return StepProgress(index: index + 1, total: chain.count)
        case .flow:
            guard let flow = current.flow else { return nil }
            return StepProgress(index: flowIndex(of: stateID, flow: flow, engine: engine, entries: entries), total: nil)
        case .intake, .watch, .cpr, .card, .triage:
            return nil
        }
    }

    /// The flow's distinct steps since it was last entered, in the order they were reached. A step
    /// come back to keeps its number. The operator panel logs only where it lands, so a forced step
    /// can read lower than a walked one.
    private static func flowIndex(of stateID: String, flow: String, engine: ProtocolEngine, entries: [LogEntry]) -> Int {
        var run: [String] = []
        for entry in entries.reversed() where entry.kind == .stateEntered {
            guard let definition = engine.definition(of: entry.detail), definition.kind == .flow, definition.flow == flow else { break }
            run.append(entry.detail)
        }
        var ordered: [String] = []
        for id in run.reversed() where !ordered.contains(id) {
            ordered.append(id)
        }
        return (ordered.firstIndex(of: stateID) ?? ordered.count) + 1
    }
}
