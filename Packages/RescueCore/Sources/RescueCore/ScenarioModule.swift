import Foundation

/// A condition's states and phrases, merged over the arrest protocol at load. Marked DRAFT until reviewed.
public struct ScenarioModule: Sendable, Equatable, Codable {
    public struct Flow: Sendable, Equatable, Codable {
        public var id: String
        public var title: String
        public var rule: String
        public var sources: [String]
    }

    /// An edge on a named state, which the module may not own.
    public struct Graft: Sendable, Equatable, Codable {
        public var state: String
        public var edge: StateDefinition.Transition
    }

    /// Load order. A module can only point at core and the modules before it.
    public static let manifest = ["triage.v1", "possible_heart_attack.v1", "possible_broken_bone.v1"]

    public static let triageState = "triage"
    /// The first step when there's an AI to do the assessing: the camera and the bystander's words
    /// decide where the rescue goes, and nobody has said yet whether the patient is awake.
    public static let assessState = "assess"
    /// Where an AED found in an awake scan shows after a collapse. It has no overlay of its own, and
    /// core's file can't give it one.
    public static let carriedAEDState = "compressions"
    /// The pin's step that has hands pressing on the wound, so "keep as found" is the wrong line there.
    public static let handsOnInjuryState = "limb_danger"
    static let breathingQuestion = "intake_breathing"
    /// An edge saying one of these has ruled aspirin out for the rest of the rescue.
    static let noAspirinPhrases: Set<String> = ["aspirin_skip", "aspirin_stop"]

    /// The one edge a module may take from core. "Yes, responding" already leaves the arrest path.
    static let onlyMovableCoreEdge = Graft(state: "intake_responsive", edge: .init(on: "human.yes", to: triageState))
    /// The one edge a module may add to a core card. Cards show on arrest-only rescues too, and every
    /// tap edge on one is a button.
    static let onlyGraftableCoreEntry = Graft(state: "responsive_patient", edge: .init(on: "human.triage_open", to: triageState))

    /// Every awake state gets these, so a module can't leave a collapse with nowhere to go.
    static func injectedEdges(triageLoaded: Bool) -> [StateDefinition.Transition] {
        var edges: [StateDefinition.Transition] = [
            .init(on: "human.start_cpr", to: "compressions", phrases: ["call_911", "hands_center"], log: .callPrompted, cutsPhrases: true),
            .init(on: "human.patient_unresponsive", to: breathingQuestion, cutsPhrases: true),
            .init(on: "human.ems_arrived", to: "handoff"),
            // Yes says the patient is awake, not that they're an adult, and the adult flows end in a dose.
            .init(on: "human.not_adult", to: "special_patient"),
            .init(on: "model.unresponsive", to: breathingQuestion, cutsPhrases: true),
            // Not call_911, for either: an awake patient short of breath would get compression prompts
            // with no human input. The question's own timeout still reaches CPR inside the 30 s bar.
            .init(on: "model.not_breathing", to: breathingQuestion, cutsPhrases: true),
            .init(on: "model.abnormal_breathing", to: breathingQuestion, cutsPhrases: true),
        ]
        if triageLoaded { edges.append(.init(on: "human.not_this", to: triageState)) }
        return edges
    }

    /// Only assess gets these. A person who taps that the patient isn't breathing, or is only
    /// gasping, has given the human input the call step needs, as a No at the breathing question would.
    /// Core's edge, not a module's, since a module's tap may never leave the awake states.
    static let assessEdges: [StateDefinition.Transition] = [
        .init(on: "human.patient_not_breathing", to: "call_911", cutsPhrases: true),
    ]

    static let injectedKeys = Set((injectedEdges(triageLoaded: true) + assessEdges).map(\.on))

    public var version: String
    public var status: String
    public var reviewer: String?
    public var flow: Flow?
    public var states: [StateDefinition]
    public var phrases: [PhraseFile.Phrase]
    public var entries: [Graft]
    public var replacedEdges: [Graft]
    /// Added to the speech table, and only ever the module's own states.
    public var openStates: [String]
    /// Always refused when set. Decoded so a misplaced correction is named instead of ignored.
    public var correctionPhrases: [String: String]
    public var awakeCorrectionPhrases: [String: String]
    /// Resource to phrase, on the awake states that list that phrase in `allowed_say`.
    public var awakeResourceHints: [String: String]

    private enum CodingKeys: String, CodingKey {
        case version, status, reviewer, flow, states, phrases, entries, replacedEdges, openStates, correctionPhrases, awakeCorrectionPhrases
        case awakeResourceHints
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        status = try c.decode(String.self, forKey: .status)
        reviewer = try c.decodeIfPresent(String.self, forKey: .reviewer)
        flow = try c.decodeIfPresent(Flow.self, forKey: .flow)
        states = try c.decode([StateDefinition].self, forKey: .states)
        phrases = try c.decodeIfPresent([PhraseFile.Phrase].self, forKey: .phrases) ?? []
        entries = try c.decodeIfPresent([Graft].self, forKey: .entries) ?? []
        replacedEdges = try c.decodeIfPresent([Graft].self, forKey: .replacedEdges) ?? []
        openStates = try c.decodeIfPresent([String].self, forKey: .openStates) ?? []
        correctionPhrases = try c.decodeIfPresent([String: String].self, forKey: .correctionPhrases) ?? [:]
        awakeCorrectionPhrases = try c.decodeIfPresent([String: String].self, forKey: .awakeCorrectionPhrases) ?? [:]
        awakeResourceHints = try c.decodeIfPresent([String: String].self, forKey: .awakeResourceHints) ?? [:]
    }
}

/// A module file as found. Decoding happens in `merging`, so a bad file is named like any other refusal.
public struct ModuleSource: Sendable, Equatable {
    public var id: String
    /// Nil when the file is missing.
    public var data: Data?

    public init(id: String, data: Data?) {
        self.id = id
        self.data = data
    }
}

public struct ModuleFailure: Sendable, Equatable {
    public var id: String
    public var reason: String
}

/// Approved text for the AI voice to draw on. No approved text, no free speech.
public struct KnowledgePack: Sendable, Equatable, Codable {
    public struct Topic: Sendable, Equatable, Codable {
        public var id: String
        public var title: String
        public var source: String
        public var text: String
    }

    public static let id = "knowledge_pack.v1"

    public var version: String
    public var status: String
    public var reviewer: String?
    public var topics: [Topic]

    init?(data: Data) {
        guard let pack = try? ProtocolBundle.clinicalDecoder().decode(KnowledgePack.self, from: data),
              !pack.topics.isEmpty,
              pack.topics.allSatisfy({ !$0.text.isBlank && !$0.source.isBlank }),
              // The AI voice draws on this, so it answers to the same rules as a module's phrases.
              pack.topics.allSatisfy({ TranscriptValidator.check($0.text, profile: .awake).isEmpty })
        else { return nil }
        self = pack
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private struct ModuleRefusal: Error {
    var reason: String
}

extension ProtocolBundle {
    /// This bundle plus every module that passes, in the order given. A refused module adds nothing
    /// but its name to `moduleFailures`, so duplicates never reach `ProtocolEngine.init`.
    public func merging(modules: [ModuleSource], pack: Data?) -> ProtocolBundle {
        var merged = self
        let corePhrases = Set(phrases.phrases.map(\.id))
        for source in modules {
            do {
                merged = try merged.adding(source, corePhrases: corePhrases)
            } catch {
                merged.moduleFailures.append(ModuleFailure(id: source.id, reason: error.reason))
            }
        }

        merged.knowledgePack = pack.flatMap(KnowledgePack.init(data:))
        if merged.knowledgePack == nil {
            merged.moduleFailures.append(ModuleFailure(id: KnowledgePack.id, reason: pack == nil ? "missing" : "invalid"))
            merged = merged.closingAwakeVoice()
        }
        return merged
    }

    /// What the app can say out loud in an awake state, so the AI can tell that voice from a person's.
    /// Never the dose, which the model must not learn.
    public var awakeLines: [String] {
        let awake = definition.states.filter(\.kind.isAwake)
        let awakeIDs = Set(awake.map(\.id))
        let ids = awake.flatMap { state in
            (state.logOnEnter == .aspirinAdvised ? [] : state.entryPhrases) + state.allowedSay + state.repeating.map(\.phrase)
                + (state.timeout?.phrases ?? []) + state.transitions.filter { awakeIDs.contains($0.to) }.flatMap { $0.phrases ?? [] }
        }
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }.compactMap(text(forPhrase:))
    }

    /// Opens on the assess step when it loaded. Only for a rescue with an AI to do the assessing,
    /// since with none the step would only wait out its timer before asking what it always asked.
    public func startingWithAssessment() -> ProtocolBundle {
        guard definition.states.contains(where: { $0.id == ScenarioModule.assessState }) else { return self }
        var opened = self
        opened.definition.initialState = ScenarioModule.assessState
        return opened
    }

    /// The flows run on by local phrases and taps, with no AI voice in any awake state.
    public func closingAwakeVoice() -> ProtocolBundle {
        var closed = self
        let awake = Set(definition.states.filter(\.kind.isAwake).map(\.id))
        closed.definition.speechGate.openStates.removeAll(where: awake.contains)
        return closed
    }

    private func adding(_ source: ModuleSource, corePhrases: Set<String>) throws(ModuleRefusal) -> ProtocolBundle {
        guard let data = source.data else { throw ModuleRefusal(reason: "missing") }
        guard let module = try? Self.clinicalDecoder().decode(ScenarioModule.self, from: data) else {
            throw ModuleRefusal(reason: "does not decode")
        }
        if let reason = BundleValidator.refusal(of: module, joining: self) { throw ModuleRefusal(reason: reason) }

        var next = self
        let triageLoaded = (definition.states + module.states).contains { $0.id == ScenarioModule.triageState }
        next.definition.states += module.states.map { state in
            var state = state
            state.transitions += ScenarioModule.injectedEdges(triageLoaded: triageLoaded)
            if state.id == ScenarioModule.assessState { state.transitions += ScenarioModule.assessEdges }
            return state
        }
        next.phrases.phrases += module.phrases
        for entry in module.entries {
            guard let index = next.definition.states.firstIndex(where: { $0.id == entry.state }) else { continue }
            next.definition.states[index].transitions.append(entry.edge)
        }
        for replaced in module.replacedEdges {
            guard let index = next.definition.states.firstIndex(where: { $0.id == replaced.state }),
                  let edge = next.definition.states[index].transitions.firstIndex(where: { $0.on == replaced.edge.on })
            else { continue }
            next.definition.states[index].transitions[edge] = replaced.edge
        }
        next.definition.speechGate.openStates += module.openStates
        next.awakeCorrectionPhrases.merge(module.awakeCorrectionPhrases) { current, _ in current }
        next.awakeResourceHints.merge(module.awakeResourceHints) { current, _ in current }
        if let flow = module.flow { next.flows.append(flow) }

        if let reason = BundleValidator.refusal(of: module, merged: next, corePhrases: corePhrases) { throw ModuleRefusal(reason: reason) }
        return next
    }
}
