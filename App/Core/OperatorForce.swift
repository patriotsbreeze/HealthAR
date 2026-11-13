import Foundation
import RescueCore

/// Stage control: gets to any state by walking the engine's own transitions, so a forced state is
/// still a state the engine produced, with its real metronome, overlay, policy, and phrases. Only
/// the destination speaks and logs, and invented answers along the way aren't recorded as fact.
enum OperatorForce {
    enum Step: Equatable {
        case human(HumanAction)
        case timeout(seconds: TimeInterval, breaths: Int)
    }

    static func path(engine: ProtocolEngine, from start: String, to target: String) -> [Step]? {
        var visited: Set<String> = [start]
        var queue: [(id: String, steps: [Step])] = [(start, [])]
        var index = 0
        while index < queue.count {
            let (id, steps) = queue[index]
            index += 1
            if id == target { return steps }
            guard let definition = engine.definition(of: id) else { continue }
            for (next, step) in edges(of: definition) where visited.insert(next).inserted {
                queue.append((next, steps + [step]))
            }
        }
        return nil
    }

    private static func edges(of definition: StateDefinition) -> [(String, Step)] {
        var edges: [(String, Step)] = definition.transitions.compactMap { transition in
            guard transition.on.hasPrefix("human."),
                  let action = HumanAction(rawValue: String(transition.on.dropFirst("human.".count)))
            else { return nil }
            return (transition.to, .human(action))
        }
        if let timeout = definition.timeout {
            edges.append((timeout.to, .timeout(seconds: timeout.seconds, breaths: 0)))
            if let rule = timeout.ifBreathsAtLeast {
                edges.append((rule.to, .timeout(seconds: timeout.seconds, breaths: rule.count)))
            }
        }
        return edges
    }

    /// Checked before the walk, and greyed out on the panel, so a refused tap isn't a silent one.
    static func refuses(engine: ProtocolEngine, state: RescueState, target: String) -> Bool {
        guard let destination = engine.definition(of: target) else { return true }
        // Every tap in the flow would obey the lock but this one, and the steps past it would give
        // aspirin and free AI to a patient who needed CPR.
        if destination.kind.isAwake, state.padsOn || state.cprStarted { return true }
        // The walk clears the aspirin record so the path lands where it was sent, and that would let the
        // dose play a second time, or after someone reported an aspirin risk.
        return destination.logOnEnter == .aspirinAdvised && (state.aspirinAdvised || state.aspirinRuledOut)
    }

    static func walk(engine: ProtocolEngine, from state: RescueState, to target: String, at now: TimeInterval) -> ReduceResult? {
        guard target != state.stateID,
              !refuses(engine: engine, state: state, target: target),
              let steps = path(engine: engine, from: state.stateID, to: target)
        else { return nil }
        let destination = engine.definition(of: target)

        var working = state
        var last: ReduceResult?
        var padsOn = state.padsOn
        for step in steps {
            // The path has to land where it was sent, so the engine's redirects stay out of it.
            working.padsOn = false
            working.cprStarted = false
            working.aspirinAdvised = false
            working.aspirinRuledOut = false
            let result: ReduceResult
            switch step {
            case let .human(action):
                result = engine.reduce(working, .human(action), at: now)
            case let .timeout(seconds, breaths):
                working.enteredAt = now - seconds
                working.breathsMarked = breaths
                result = engine.reduce(working, .tick, at: now)
            }
            working = result.state
            padsOn = padsOn || working.padsOn
            last = result
        }
        guard var merged = last, working.stateID == target else { return nil }
        merged.state.padsOn = padsOn
        // Walking through CPR on the way is no CPR on the record, and backing out on the way is nobody's choice.
        merged.state.cprStarted = state.cprStarted || destination?.kind == .cpr
        merged.state.aspirinAdvised = state.aspirinAdvised || working.aspirinAdvised
        // Only an edge's "No aspirin" rules it out on the way, and that line is stripped below as nobody's answer.
        merged.state.aspirinRuledOut = state.aspirinRuledOut
        merged.state.declinedFlows = state.declinedFlows

        // Only the net metronome change, or the path would click on and off.
        var effects = merged.effects.filter {
            if case .metronome = $0 { false } else { true }
        }
        if state.metronomeOn != working.metronomeOn {
            effects.insert(.metronome(on: working.metronomeOn), at: 0)
        }
        // Nothing said for the old step is wanted on stage.
        effects.insert(.dropQueuedPhrases(keeping: []), at: 0)
        // An edge's line answers something nobody was asked, like "No aspirin" on a forced wait.
        if let destination, destination.kind.isAwake {
            effects.removeAll {
                if case let .playPhrase(id) = $0 { !destination.entryPhrases.contains(id) } else { false }
            }
        }
        // The engine briefed the walk's last step, whose record isn't the one that stands.
        if let destination {
            effects = effects.map {
                if case .sendStateBrief = $0 { .sendStateBrief(engine.brief(for: merged.state, definition: destination, at: now)) } else { $0 }
            }
        }
        merged.effects = effects

        let invented: Set<LogEntry.Kind> = [.answer, .patientMoved, .flowEntered]
        merged.log = [LogEntry.Draft(kind: .stateEntered, source: .system, detail: "operator_forced:\(target)")]
            + merged.log.filter { !invented.contains($0.kind) }.map { entry in
                // Only a tap advises a dose, and nobody tapped this one.
                entry.kind == .aspirinAdvised ? LogEntry.Draft(kind: entry.kind, source: .system, detail: entry.detail) : entry
            }
        // Only the last step's log survives, and whichever step crossed into the flow wasn't a person.
        if let flow = engine.definition(of: target)?.flow, flow != engine.definition(of: state.stateID)?.flow {
            merged.log.append(LogEntry.Draft(kind: .flowEntered, source: .system, detail: flow))
        }
        return merged
    }
}
