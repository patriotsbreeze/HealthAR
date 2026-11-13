import Foundation
import Testing
@testable import RescueCore

private func state(
    _ id: String,
    kind: String = "flow",
    urgency: Int = 2,
    flow: String? = "possible_demo",
    entry: [String] = [],
    edges: [[String: Any]] = [],
    extra: [String: Any] = [:]
) -> [String: Any] {
    var fields: [String: Any] = [
        "id": id,
        "kind": kind,
        "urgency": urgency,
        "entry_phrases": entry,
        "metronome": "off",
        "frame_uplink": false,
        "allowed_say": [String](),
        "transitions": edges,
        "citation": "Fixture",
    ]
    if let flow { fields["flow"] = flow }
    return fields.merging(extra) { _, new in new }
}

private func phrase(_ id: String, _ text: String = "A short fixture line.", citation: String = "Fixture") -> [String: Any] {
    ["id": id, "text": text, "citation": citation]
}

private func edge(_ on: String, to: String, extra: [String: Any] = [:]) -> [String: Any] {
    ["on": on, "to": to].merging(extra) { _, new in new }
}

private func graft(_ state: String, _ on: String, to: String) -> [String: Any] {
    ["state": state, "edge": edge(on, to: to)]
}

/// Everything a module can do, in one file that passes. Each bad case below breaks one thing in it.
private func goodModule() -> [String: Any] {
    [
        "version": "fixture.v1",
        "status": "DRAFT",
        "flow": ["id": "possible_demo", "title": "Possible demo", "rule": "A demo finding in an awake adult.", "sources": ["Fixture"]],
        "states": [
            state("triage", kind: "triage", urgency: 0, flow: nil, entry: ["demo_ask"], edges: [
                edge("human.triage_chest", to: "demo_call"),
                edge("model.chest_pain", to: "demo_call", extra: ["min_confidence": "medium"]),
            ], extra: ["after_pads": "responsive_patient"]),
            state("demo_call", entry: ["demo_line"], edges: [edge("human.done", to: "demo_wait")], extra: [
                "timeout": ["seconds": 10, "to": "demo_wait"],
            ]),
            state("demo_wait", entry: ["demo_line"], extra: [
                "repeating": [["phrase": "demo_line", "every_seconds": 30]],
            ]),
        ],
        "phrases": [phrase("demo_ask"), phrase("demo_line")],
        "entries": [graft("responsive_patient", "human.triage_open", to: "triage")],
        "replaced_edges": [graft("intake_responsive", "human.yes", to: "triage")],
        "open_states": ["triage", "demo_wait"],
    ]
}

/// Records a dose, and goes on where a repeat of it would.
private func aspirinState(_ id: String = "demo_aspirin") -> [String: Any] {
    state(id, extra: ["log_on_enter": "aspirin_advised", "timeout": ["seconds": 15, "to": "demo_wait"]])
}

private let doseText = "Chew and swallow one 325 mg aspirin, or two 81 mg."

/// A second flow, for what happens between modules.
private func laterModule() -> [String: Any] {
    [
        "version": "later.v1",
        "status": "DRAFT",
        "flow": ["id": "possible_later", "title": "Possible later", "rule": "A later finding.", "sources": ["Fixture"]],
        "states": [state("later_start", urgency: 1, flow: "possible_later", entry: ["later_line"])],
        "phrases": [phrase("later_line")],
        "entries": [graft("triage", "human.triage_limb", to: "later_start")],
    ]
}

private func json(_ fields: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: fields)
}

private func source(_ fields: [String: Any], id: String = "fixture") throws -> ModuleSource {
    ModuleSource(id: id, data: try json(fields))
}

private func shippedPack() throws -> Data {
    try Data(contentsOf: repoRoot().appendingPathComponent("clinical/\(KnowledgePack.id).json"))
}

private func arrestStates(_ bundle: ProtocolBundle) -> [StateDefinition] {
    bundle.definition.states.filter(\.kind.isArrestPath)
}

/// Runs it through the real engine, since `ProtocolEngine.init` is where a duplicate would trap.
private func expectRuns(_ bundle: ProtocolBundle, sourceLocation: SourceLocation = #_sourceLocation) {
    var session = Session(engine: ProtocolEngine(bundle: bundle))
    session.human(.no)
    #expect(session.state.stateID == "intake_breathing", sourceLocation: sourceLocation)
}

/// A refused module leaves no trace but its name.
private func expectRefused(_ module: ModuleSource, because reason: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let core = try loadBundle()
    let merged = core.merging(modules: [module], pack: try shippedPack())
    #expect(merged.moduleFailures.count == 1, sourceLocation: sourceLocation)
    #expect(merged.moduleFailures.first?.id == module.id, sourceLocation: sourceLocation)
    let got = merged.moduleFailures.first?.reason ?? ""
    #expect(got.contains(reason), "refused for: \(got)", sourceLocation: sourceLocation)
    #expect(arrestStates(merged) == arrestStates(core), sourceLocation: sourceLocation)
    #expect(merged.definition == core.definition, sourceLocation: sourceLocation)
    #expect(merged.phrases == core.phrases, sourceLocation: sourceLocation)
    #expect(merged.flows.isEmpty, sourceLocation: sourceLocation)
    expectRuns(merged, sourceLocation: sourceLocation)
}

private func expectRefused(_ reason: String, sourceLocation: SourceLocation = #_sourceLocation, _ change: (inout [String: Any]) -> Void) throws {
    var module = goodModule()
    change(&module)
    try expectRefused(try source(module), because: reason, sourceLocation: sourceLocation)
}

private func changeState(_ index: Int, in module: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
    var states = module["states"] as? [[String: Any]] ?? []
    change(&states[index])
    module["states"] = states
}

private func addEdge(_ new: [String: Any], toState index: Int, in module: inout [String: Any]) {
    changeState(index, in: &module) { state in
        state["transitions"] = (state["transitions"] as? [[String: Any]] ?? []) + [new]
    }
}

private func addState(_ new: [String: Any], in module: inout [String: Any]) {
    module["states"] = (module["states"] as? [[String: Any]] ?? []) + [new]
}

private func mergedEngine() throws -> ProtocolEngine {
    ProtocolEngine(bundle: try loadBundle().merging(modules: [try source(goodModule())], pack: try shippedPack()))
}

@Suite struct ModuleLoadTests {
    // MARK: - A good module

    @Test func aGoodModuleMerges() throws {
        let core = try loadBundle()
        let merged = core.merging(modules: [try source(goodModule())], pack: try shippedPack())

        #expect(merged.moduleFailures.isEmpty)
        #expect(merged.flows.map(\.id) == ["possible_demo"])
        #expect(merged.text(forPhrase: "demo_ask") != nil)
        #expect(merged.knowledgePack != nil)
        #expect(BundleValidator.isRunnable(merged))
    }

    @Test func everyAwakeStateGetsTheInjectedEdges() throws {
        let merged = try loadBundle().merging(modules: [try source(goodModule())], pack: try shippedPack())
        let awake = merged.definition.states.filter(\.kind.isAwake)
        #expect(awake.count == 3)

        let targets = [
            "human.start_cpr": "compressions",
            "human.patient_unresponsive": "intake_breathing",
            "human.ems_arrived": "handoff",
            "human.not_adult": "special_patient",
            "human.not_this": "triage",
            "model.unresponsive": "intake_breathing",
            "model.not_breathing": "intake_breathing",
            "model.abnormal_breathing": "intake_breathing",
        ]
        let collapses: Set = [
            "human.start_cpr", "human.patient_unresponsive", "model.unresponsive", "model.not_breathing", "model.abnormal_breathing",
        ]
        for state in awake {
            for (key, target) in targets {
                let transition = state.transition(on: key)
                #expect(transition?.to == target, "\(state.id) \(key)")
                #expect(transition?.cutsPhrases == collapses.contains(key), "\(state.id) \(key)")
            }
            let startCPR = state.transition(on: "human.start_cpr")
            #expect(startCPR?.phrases == ["call_911", "hands_center"])
            #expect(startCPR?.log == .callPrompted)
        }
    }

    @Test func onlyHumanYesMovesInCore() throws {
        let core = try loadBundle()
        let merged = core.merging(modules: [try source(goodModule())], pack: try shippedPack())
        let moved = "intake_responsive"

        #expect(arrestStates(merged).filter { $0.id != moved } == arrestStates(core).filter { $0.id != moved })

        let before = try #require(core.definition.states.first { $0.id == moved })
        let after = try #require(merged.definition.states.first { $0.id == moved })
        #expect(before.transition(on: "human.yes")?.to == "responsive_patient")
        #expect(after.transition(on: "human.yes")?.to == "triage")
        #expect(after.transitions.map(\.on) == before.transitions.map(\.on))
        #expect(after.transitions.filter { $0.on != "human.yes" } == before.transitions.filter { $0.on != "human.yes" })
    }

    @Test func anEntryAddsOneEdgeToItsState() throws {
        let core = try loadBundle()
        let merged = core.merging(modules: [try source(goodModule())], pack: try shippedPack())
        let before = try #require(core.definition.states.first { $0.id == "responsive_patient" })
        let after = try #require(merged.definition.states.first { $0.id == "responsive_patient" })
        #expect(after.transitions.dropLast() == before.transitions[...])
        #expect(after.transitions.last?.on == "human.triage_open")
        #expect(after.transitions.last?.to == "triage")
    }

    @Test func theSpeechTableAddsToCoresList() throws {
        let core = try loadBundle()
        let list = core.definition.speechGate.openStates
        let merged = core.merging(modules: [try source(goodModule())], pack: try shippedPack())

        #expect(merged.definition.speechGate.openStates == list + ["triage", "demo_wait"])
        #expect(core.definition.speechGate.openStates == list)
    }

    @Test func theEngineRunsTheMergedGraph() throws {
        let merged = try loadBundle().merging(modules: [try source(goodModule())], pack: try shippedPack())
        let engine = ProtocolEngine(bundle: merged)

        var tapped = Session(engine: engine)
        tapped.human(.yes)
        #expect(tapped.state.stateID == "triage")
        #expect(engine.policy(for: tapped.state, at: tapped.now).modelSpeechOpen)
        tapped.human(.triageChest)
        #expect(tapped.state.stateID == "demo_call")
        tapped.human(.startCpr)
        #expect(tapped.state.stateID == "compressions")
        #expect(tapped.effects.contains(.cutPhrases))
        #expect(tapped.phrases == ["call_911", "hands_center", "start_compressions"])

        var heard = Session(engine: engine)
        heard.human(.yes)
        heard.model(.reportFinding(.chestPain, source: .heard, confidence: .low))
        #expect(heard.state.stateID == "triage", "below the edge's confidence")
        heard.modelFinding(.chestPain)
        #expect(heard.state.stateID == "demo_call")
        heard.modelFinding(.unresponsive)
        #expect(heard.state.stateID == "intake_breathing")
        #expect(heard.effects.contains(.cutPhrases))
    }

    @Test func notThisGoesBackToTriageWithoutCuttingAnything() throws {
        let merged = try loadBundle().merging(modules: [try source(goodModule())], pack: try shippedPack())
        var session = Session(engine: ProtocolEngine(bundle: merged))
        session.human(.yes)
        session.human(.triageChest)
        session.human(.notThis)
        #expect(session.state.stateID == "triage")
        #expect(!session.effects.contains(.cutPhrases))
    }

    @Test func aGuideIsOptionalAndCoreDeclaresNone() throws {
        let core = try loadBundle()
        #expect(core.definition.states.allSatisfy { $0.guide == nil })

        var module = goodModule()
        changeState(1, in: &module) { $0["guide"] = "sit_rest" }
        let merged = core.merging(modules: [try source(module)], pack: try shippedPack())
        #expect(merged.moduleFailures.isEmpty, "\(merged.moduleFailures)")
        #expect(merged.definition.states.first { $0.id == "demo_call" }?.guide == .sitRest)
    }

    @Test func aGuideThisBuildCannotDrawDropsTheModule() throws {
        try expectRefused("does not decode") { module in
            changeState(1, in: &module) { $0["guide"] = "tourniquet_diagram" }
        }
    }

    @Test func notThisIsOnlyInjectedOnceTriageIsLoaded() throws {
        var module = laterModule()
        module["entries"] = [[String: Any]]()
        let merged = try loadBundle().merging(modules: [try source(module)], pack: try shippedPack())
        #expect(merged.moduleFailures.isEmpty)
        let later = try #require(merged.definition.states.first { $0.id == "later_start" })
        #expect(later.transition(on: "human.not_this") == nil)
        #expect(later.transition(on: "human.start_cpr") != nil)
    }

    // MARK: - After Yes

    /// Yes says the patient is awake, not that they're an adult, and the adult flows end in a dose.
    @Test func anAwakeStateCanStillLeaveForTheDispatcherLedCard() throws {
        var fromTriage = Session(engine: try mergedEngine())
        fromTriage.human(.yes)
        fromTriage.human(.notAdult)
        #expect(fromTriage.state.stateID == "special_patient")
        #expect(fromTriage.entries(.answer).last?.detail == "adult=no")

        var fromFlow = Session(engine: try mergedEngine())
        fromFlow.human(.yes)
        fromFlow.human(.triageChest)
        fromFlow.human(.notAdult)
        #expect(fromFlow.state.stateID == "special_patient")
    }

    /// A patient who is talking gets asked first, however sure the report sounds.
    @Test(arguments: [Finding.notBreathing, .abnormalBreathing, .unresponsive])
    func aCollapseReportAsksAboutBreathingAndStillReachesCPRInTime(finding: Finding) throws {
        var session = Session(engine: try mergedEngine())
        session.human(.yes)
        let reported = session.now
        session.model(.reportFinding(finding, source: .heard, confidence: .low))
        #expect(session.state.stateID == "intake_breathing")
        #expect(!session.state.metronomeOn)

        for seconds in [10.0, 5, 5, 5] { session.advance(seconds) }
        #expect(session.state.stateID == "compressions")
        #expect(session.state.metronomeOn)
        #expect(session.now - reported <= 30)
        #expect(session.entries(.answer).contains { $0.detail == "breathing=no_reply" })
    }

    // MARK: - Reports from before the tap

    /// Yes voided these before there was a stale rule, and a person's answer still outranks them.
    @Test(arguments: [Finding.unresponsive, .notBreathing, .abnormalBreathing])
    func aReportFromBeforeYesDoesNotOverrideIt(finding: Finding) throws {
        var session = Session(engine: try mergedEngine())
        #expect(session.state.stateID == "intake_responsive")
        let old = session.proposal(.reportFinding(finding, source: .heard, confidence: .low))
        session.human(.yes)
        #expect(session.state.stateID == "triage")

        let before = session.state
        session.now += 1
        session.send(.model(old))
        #expect(session.state == before)
        #expect(session.entries(.finding).isEmpty)
        #expect(session.entries(.proposalRejected).last?.detail.hasSuffix("stale_version") == true)
    }

    /// The other side of the line: stale, but about a patient already known to be awake.
    @Test(arguments: [Finding.unresponsive, .notBreathing, .abnormalBreathing])
    func aReportFromAfterYesStillCounts(finding: Finding) throws {
        var session = Session(engine: try mergedEngine())
        session.human(.yes)
        let old = session.proposal(.reportFinding(finding, source: .heard, confidence: .low))
        session.human(.triageChest)
        #expect(session.state.stateID == "demo_call")
        session.send(.model(old))
        #expect(session.state.stateID == "intake_breathing")
    }

    /// Coming back to the awake states draws the line again.
    @Test func aReportFromBeforeTheLatestReturnIsStale() throws {
        var session = Session(engine: try mergedEngine())
        session.human(.yes)
        let old = session.proposal(.reportFinding(.notBreathing, source: .heard, confidence: .high))
        session.human(.patientUnresponsive)
        session.human(.yes)
        session.human(.patientAwake)
        #expect(session.state.stateID == "responsive_patient")
        session.human(.triageOpen)
        #expect(session.state.stateID == "triage")

        let before = session.state
        session.send(.model(old))
        #expect(session.state == before)
        #expect(session.entries(.proposalRejected).last?.detail.hasSuffix("stale_version") == true)
    }

    // MARK: - Who stays on the static card

    private func expectStaysOnTheCard(_ session: inout Session, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(session.state.stateID == "responsive_patient", sourceLocation: sourceLocation)
        session.human(.triageOpen)
        #expect(session.state.stateID == "responsive_patient", sourceLocation: sourceLocation)
        #expect(!session.engine.policy(for: session.state, at: session.now).modelSpeechOpen, sourceLocation: sourceLocation)
        #expect(session.entries(.flowEntered).isEmpty, sourceLocation: sourceLocation)
    }

    @Test func aPatientWhoWakesAfterCPRStaysOnTheCard() throws {
        var session = Session(engine: try mergedEngine())
        session.human(.startCpr)
        session.human(.patientMoving)
        session.human(.patientAwake)
        #expect(!session.state.padsOn)
        try expectStaysOnTheCard(&session)
    }

    @Test func aPatientWithPadsOnStaysOnTheCard() throws {
        var session = Session(engine: try mergedEngine())
        session.goToAnalysis()
        session.human(.patientMoving)
        session.human(.patientAwake)
        #expect(session.state.padsOn)
        try expectStaysOnTheCard(&session)
    }

    /// Yes at intake is a door too, and Back from the special card leads to it.
    @Test func noWayRoundTheCardAfterCPR() throws {
        var session = Session(engine: try mergedEngine())
        session.human(.startCpr)
        session.human(.patientMoving)
        session.human(.patientAwake)
        session.human(.patientUnresponsive)
        session.human(.notAdult)
        session.human(.back)
        #expect(session.state.stateID == "intake_responsive")
        session.human(.yes)
        try expectStaysOnTheCard(&session)
    }

    /// Waking without CPR is nothing the plan keeps out of triage. Breathing all along, then awake.
    @Test func aPatientWhoNeverNeededCPRCanStillOpenTriage() throws {
        var session = Session(engine: try mergedEngine())
        session.human(.no)
        session.human(.yes)
        session.human(.patientAwake)
        #expect(session.state.stateID == "responsive_patient")
        session.human(.triageOpen)
        #expect(session.state.stateID == "triage")
        #expect(session.engine.policy(for: session.state, at: session.now).modelSpeechOpen)
    }

    /// `call_911` redirects to `compressions_aed` for pads, and pads aren't what happened here.
    @Test func cprAloneLeavesTheArrestRedirectsAlone() throws {
        var session = Session(engine: try mergedEngine())
        session.human(.startCpr)
        session.human(.patientMoving)
        session.advance(10)
        #expect(session.state.stateID == "call_911")
        #expect(session.state.cprStarted)
        #expect(!session.state.padsOn)
    }

    // MARK: - Refused, with nothing applied

    @Test func garbageIsRefused() throws {
        try expectRefused(ModuleSource(id: "fixture", data: Data("not json".utf8)), because: "does not decode")
        try expectRefused(ModuleSource(id: "fixture", data: Data("{}".utf8)), because: "does not decode")
        try expectRefused(ModuleSource(id: "fixture", data: Data("[]".utf8)), because: "does not decode")
        try expectRefused("does not decode") { changeState(0, in: &$0) { $0["kind"] = "nonsense" } }
    }

    @Test func aMissingFileIsNamed() throws {
        try expectRefused(ModuleSource(id: "fixture", data: nil), because: "missing")
    }

    @Test func aStateIDCollisionIsRefused() throws {
        try expectRefused("state id collision: compressions") { changeState(0, in: &$0) { $0["id"] = "compressions" } }
        try expectRefused("state id collision: demo_call") { changeState(2, in: &$0) { $0["id"] = "demo_call" } }
    }

    @Test func aPhraseIDCollisionIsRefused() throws {
        try expectRefused("phrase id collision: call_911") { $0["phrases"] = [phrase("demo_ask"), phrase("demo_line"), phrase("call_911")] }
        try expectRefused("phrase id collision: demo_ask") { $0["phrases"] = [phrase("demo_ask"), phrase("demo_ask"), phrase("demo_line")] }
    }

    @Test func aDanglingReferenceIsRefused() throws {
        try expectRefused("dangling edge") { addEdge(edge("human.done", to: "nowhere"), toState: 0, in: &$0) }
        try expectRefused("dangling timeout") { changeState(1, in: &$0) { $0["timeout"] = ["seconds": 10, "to": "nowhere"] } }
        try expectRefused("dangling after_pads") { changeState(1, in: &$0) { $0["after_pads"] = "nowhere" } }
        try expectRefused("dangling phrase") { changeState(1, in: &$0) { $0["entry_phrases"] = ["nowhere"] } }
        try expectRefused("dangling phrase") { changeState(1, in: &$0) { $0["allowed_say"] = ["nowhere"] } }
        try expectRefused("dangling phrase") { addEdge(edge("human.back", to: "triage", extra: ["phrases": ["nowhere"]]), toState: 0, in: &$0) }
        try expectRefused("dangling edge") { $0["entries"] = [graft("demo_wait", "human.back", to: "nowhere")] }
        try expectRefused("entry on unknown state") { $0["entries"] = [graft("nowhere", "human.done", to: "triage")] }
        try expectRefused("replaces unknown edge") { $0["replaced_edges"] = [graft("nowhere", "human.yes", to: "triage")] }
        try expectRefused("replaces unknown edge") { $0["replaced_edges"] = [graft("demo_call", "human.called", to: "triage")] }
        try expectRefused("dangling correction") { $0["correction_phrases"] = ["diagnosis": "nowhere"] }
    }

    @Test func anOnKeyMustBeARealEvent() throws {
        try expectRefused("unknown event") { addEdge(edge("human.teleport", to: "demo_wait"), toState: 0, in: &$0) }
        try expectRefused("unknown event") { addEdge(edge("model.teleport", to: "demo_wait"), toState: 0, in: &$0) }
        try expectRefused("unknown event") { addEdge(edge("tick", to: "demo_wait"), toState: 0, in: &$0) }
    }

    @Test(arguments: ["cpr", "intake", "watch", "setup", "card"])
    func aStateMustBeAwake(kind: String) throws {
        try expectRefused("state kind \(kind)") { changeState(1, in: &$0) { $0["kind"] = kind } }
    }

    @Test func theMetronomeStaysOff() throws {
        try expectRefused("metronome not off") { changeState(1, in: &$0) { $0["metronome"] = "on" } }
        try expectRefused("metronome not off") { changeState(1, in: &$0) { $0["metronome_toggleable"] = true } }
    }

    /// Everything but what the module's own flows can honestly say, so a new kind starts out refused.
    @Test(arguments: LogEntry.Kind.allCases.filter { $0 != .callPrompted && $0 != .aspirinAdvised })
    func aModuleCantRecordWhatOnlyARescueCan(log: LogEntry.Kind) throws {
        try expectRefused("reserved log \(log.rawValue)") { changeState(1, in: &$0) { $0["log_on_enter"] = log.rawValue } }
        try expectRefused("reserved log \(log.rawValue)") { addEdge(edge("human.back", to: "triage", extra: ["log": log.rawValue]), toState: 1, in: &$0) }
    }

    @Test func aModuleMayPromptACallAndRecordAnAspirinAdvised() throws {
        var module = goodModule()
        changeState(1, in: &module) { $0["log_on_enter"] = "call_prompted" }
        addEdge(edge("human.back", to: "demo_wait", extra: ["log": "call_prompted"]), toState: 1, in: &module)
        addEdge(edge("human.yes", to: "demo_aspirin"), toState: 1, in: &module)
        addState(aspirinState(), in: &module)
        let merged = try loadBundle().merging(modules: [try source(module)], pack: try shippedPack())
        #expect(merged.moduleFailures.isEmpty, "\(merged.moduleFailures)")
    }

    /// On the edge it wouldn't mark the state, and the model could still reach what it advises.
    @Test func anAspirinRecordBelongsOnTheState() throws {
        try expectRefused("reserved log aspirin_advised") {
            addEdge(edge("human.yes", to: "demo_wait", extra: ["log": "aspirin_advised"]), toState: 1, in: &$0)
        }
    }

    @Test(arguments: ["aed_analyze", "handoff", "compressions", "aed_on"])
    func afterPadsCantLandOnThem(target: String) throws {
        try expectRefused("after_pads sets") { changeState(1, in: &$0) { $0["after_pads"] = target } }
    }

    // MARK: - The pads guard

    @Test func triageMustHaveARedirect() throws {
        try expectRefused("no after_pads: triage") { changeState(0, in: &$0) { $0["after_pads"] = nil } }
        // Even with no way in yet, since a later module's flows lead back to it with Not this.
        try expectRefused("no after_pads: triage") {
            changeState(0, in: &$0) { $0["after_pads"] = nil }
            $0["entries"] = [[String: Any]]()
            $0["replaced_edges"] = [[String: Any]]()
        }
    }

    /// Cards show on arrest-only rescues, and every tap edge on one is a button. These would put one
    /// on the handoff card, or send the child-or-pregnant card into an adult flow that ends in a dose.
    @Test func aCardTakesOnlyTheOneEntry() throws {
        let cases = [
            graft("special_patient", "human.triage_open", to: "triage"),
            graft("handoff", "human.triage_chest", to: "triage"),
            graft("responsive_patient", "human.triage_chest", to: "demo_call"),
            graft("responsive_patient", "human.triage_open", to: "demo_wait"),
        ]
        for entry in cases {
            let card = try #require(entry["state"] as? String)
            let on = try #require((entry["edge"] as? [String: Any])?["on"] as? String)
            try expectRefused("core entry can't graft: \(card) \(on)") { $0["entries"] = [entry] }
        }
        var phrased = goodModule()
        phrased["entries"] = [["state": "responsive_patient", "edge": edge("human.triage_open", to: "triage", extra: ["phrases": ["demo_line"]])]]
        try expectRefused(try source(phrased), because: "core entry can't graft: responsive_patient human.triage_open")
    }

    /// A redirect back into the awake states would keep them on aspirin and free AI.
    @Test func aRedirectMustLeaveTheAwakeStates() throws {
        try expectRefused("after_pads stays awake") { changeState(0, in: &$0) { $0["after_pads"] = "demo_wait" } }
        try expectRefused("after_pads stays awake") { changeState(1, in: &$0) { $0["after_pads"] = "triage" } }
    }

    /// Tapping on from a state that's already awake needs none, since pads can't get there.
    @Test func anEdgeBetweenAwakeStatesNeedsNoRedirect() throws {
        var module = goodModule()
        addState(state("demo_next"), in: &module)
        addEdge(edge("human.triage_limb", to: "demo_next"), toState: 0, in: &module)
        let merged = try loadBundle().merging(modules: [try source(module)], pack: try shippedPack())
        #expect(merged.moduleFailures.isEmpty, "\(merged.moduleFailures)")
    }

    // MARK: - Where a report may land

    /// Each of these got a low-confidence report past the urgency check, with its own damage:
    /// pads latched, the beat on, EMS recorded as arrived, or nowhere left to go.
    @Test(arguments: [
        "aed_analyze", "aed_on", "pads", "compressions", "compressions_aed", "resource_scan", "handoff",
        "special_patient", "responsive_patient", "call_911", "position_patient", "place_hands",
        "watch_breathing", "watch_reask", "intake_responsive",
    ])
    func aModelEdgeCantLandThere(target: String) throws {
        try expectRefused("model edge can't land on \(target)") { addEdge(edge("model.other_concern", to: target), toState: 0, in: &$0) }
    }

    @Test func aModelEdgeCantLandThereByARedirect() throws {
        try expectRefused("model edge can't land on compressions_aed") {
            addState(state("demo_door", extra: ["after_pads": "compressions_aed"]), in: &$0)
            addEdge(edge("model.limb_injury", to: "demo_door"), toState: 0, in: &$0)
        }
    }

    /// From urgency 0 to 0, which the urgency check alone would pass.
    @Test func theModelCantReachTriage() throws {
        try expectRefused("model edge can't land on triage") { addEdge(edge("model.other_concern", to: "triage"), toState: 0, in: &$0) }
    }

    @Test func theModelCantReachAnAspirinState() throws {
        try expectRefused("model edge can't land on demo_aspirin") {
            addState(aspirinState(), in: &$0)
            addEdge(edge("model.other_concern", to: "demo_aspirin"), toState: 0, in: &$0)
        }
    }

    @Test func aModelEdgeMayGoToAnAwakeStateOrAskAboutBreathing() throws {
        var module = goodModule()
        addEdge(edge("model.limb_injury", to: "demo_wait"), toState: 0, in: &module)
        addEdge(edge("model.heavy_bleeding", to: "intake_breathing"), toState: 0, in: &module)
        let merged = try loadBundle().merging(modules: [try source(module)], pack: try shippedPack())
        #expect(merged.moduleFailures.isEmpty, "\(merged.moduleFailures)")
    }

    /// The gate checks transitions first, so these edges would talk over a dispatcher.
    @Test(arguments: ["dispatcher_speaking", "aed_prompting"])
    func aModelEdgeCantReplaceAHold(finding: String) throws {
        try expectRefused("model edge in place of a hold: model.\(finding)") { addEdge(edge("model.\(finding)", to: "demo_wait"), toState: 0, in: &$0) }
    }

    // MARK: - Where a tap may land

    /// Each of these would write the record or start something, on a tap nobody meant for it. The
    /// injected edges are the only way out, and every other test here shows they still load.
    @Test(arguments: [
        "aed_analyze", "aed_on", "pads", "compressions", "compressions_aed", "resource_scan", "handoff",
        "special_patient", "responsive_patient", "call_911", "position_patient", "place_hands",
        "watch_breathing", "watch_reask", "intake_responsive", "intake_breathing",
    ])
    func anAuthoredTapCantLeaveTheAwakeStates(target: String) throws {
        let reason = "human edge leaves the awake states: human.done to \(target)"
        try expectRefused(reason) { addEdge(edge("human.done", to: target), toState: 0, in: &$0) }
        try expectRefused(reason) { $0["entries"] = [graft("demo_wait", "human.done", to: target)] }
        // A card takes no entry but the one, so this goes before its target is looked at.
        try expectRefused("core entry can't graft: responsive_patient human.done") { $0["entries"] = [graft("responsive_patient", "human.done", to: target)] }
    }

    @Test func aLaterModuleCantReplaceATapWithOneThatLeaves() throws {
        var later = laterModule()
        later["replaced_edges"] = [graft("triage", "human.triage_chest", to: "aed_analyze")]
        let merged = try loadBundle().merging(modules: [try source(goodModule(), id: "first"), try source(later, id: "later")], pack: try shippedPack())
        #expect(merged.moduleFailures.first?.reason.contains("human edge leaves the awake states") == true)
        #expect(merged.definition.states.first { $0.id == "triage" }?.transition(on: "human.triage_chest")?.to == "demo_call")
    }

    // MARK: - Where a timeout may land

    @Test(arguments: ["responsive_patient", "handoff", "special_patient"])
    func aTimeoutCantLandOnACard(target: String) throws {
        // From urgency 0, so the urgency check doesn't get there first.
        try expectRefused("timeout onto a card") { changeState(0, in: &$0) { $0["timeout"] = ["seconds": 5, "to": target] } }
    }

    @Test func aTimeoutCantLandOnACardByItsBreathGuard() throws {
        try expectRefused("timeout onto a card") {
            changeState(1, in: &$0) { state in
                state["timeout"] = ["seconds": 10, "to": "demo_wait", "if_breaths_at_least": ["count": 2, "to": "special_patient"]]
            }
        }
    }

    /// With pads on the timer would land in CPR and play the compressions prompt, with nobody touching anything.
    @Test func aTimeoutCantLandInCPRByARedirect() throws {
        try expectRefused("timeout into the arrest path: demo_call to compressions_aed") {
            changeState(2, in: &$0) { $0["after_pads"] = "compressions_aed" }
        }
    }

    /// Silence takes the safer branch, which is no aspirin.
    @Test func aTimeoutCantLandOnAnAspirinState() throws {
        try expectRefused("timeout into a human-only state: demo_call to demo_aspirin") {
            addState(aspirinState(), in: &$0)
            changeState(1, in: &$0) { $0["timeout"] = ["seconds": 10, "to": "demo_aspirin"] }
        }
    }

    // MARK: - The one dose

    private func withDose(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
        var module = goodModule()
        module["phrases"] = (module["phrases"] as? [[String: Any]] ?? []) + [phrase("aspirin_give", doseText)]
        addState(state("demo_aspirin", entry: ["aspirin_give"], extra: ["log_on_enter": "aspirin_advised", "timeout": ["seconds": 15, "to": "demo_wait"]]), in: &module)
        change(&module)
        return module
    }

    @Test func theDoseMayBeSaidOnEnteringAStepThatRecordsIt() throws {
        var module = withDose { _ in }
        addEdge(edge("human.yes", to: "demo_aspirin"), toState: 1, in: &module)
        let merged = try loadBundle().merging(modules: [try source(module)], pack: try shippedPack())
        #expect(merged.moduleFailures.isEmpty, "\(merged.moduleFailures)")
    }

    @Test func theDoseIsSaidNowhereElse() throws {
        let cases: [(String, (inout [String: Any]) -> Void)] = [
            ("allowed_say", { changeState(1, in: &$0) { $0["allowed_say"] = ["aspirin_give"] } }),
            ("an entry with no aspirin log", { changeState(1, in: &$0) { $0["entry_phrases"] = ["aspirin_give"] } }),
            ("a repeat", { changeState(2, in: &$0) { $0["repeating"] = [["phrase": "aspirin_give", "every_seconds": 30]] } }),
            ("a model edge", { addEdge(edge("model.limb_injury", to: "demo_wait", extra: ["phrases": ["aspirin_give"]]), toState: 1, in: &$0) }),
            ("a tap edge", { addEdge(edge("human.yes", to: "demo_wait", extra: ["phrases": ["aspirin_give"]]), toState: 1, in: &$0) }),
            ("a timeout", { changeState(1, in: &$0) { $0["timeout"] = ["seconds": 10, "to": "demo_wait", "phrases": ["aspirin_give"]] } }),
            ("said twice on the way in", { module in
                var states = module["states"] as? [[String: Any]] ?? []
                states[states.count - 1]["entry_phrases"] = ["aspirin_give", "aspirin_give"]
                module["states"] = states
            }),
        ]
        for (name, change) in cases {
            let module = withDose(change)
            let merged = try loadBundle().merging(modules: [try source(module)], pack: try shippedPack())
            #expect(merged.moduleFailures.first?.reason.contains("dose outside an aspirin step") == true, "\(name): \(merged.moduleFailures)")
        }
    }

    @Test func anAspirinStepHasToHaveSomewhereToGoForARepeat() throws {
        try expectRefused("aspirin step has no timeout") {
            addState(state("demo_aspirin", extra: ["log_on_enter": "aspirin_advised"]), in: &$0)
        }
    }

    // MARK: - What a phrase may say

    @Test(arguments: [
        ("Give 500 mg of aspirin.", "dose"),
        ("This is a heart attack.", "diagnosis"),
        ("I'm a nurse, stay calm.", "identity"),
        ("You don't need an ambulance.", "discourage_emergency"),
        ("Check for a pulse.", "pulse_check"),
    ])
    func aPhraseIsHeldToTheAwakeRules(text: String, rule: String) throws {
        try expectRefused("phrase breaks the \(rule) rule: demo_line") { module in
            module["phrases"] = [phrase("demo_ask"), phrase("demo_line", text)]
        }
    }

    /// The transcript check lets each of these through, since naming a drug is ordinary in speech. In a
    /// module it would be a dose on a step a timer or a report can reach, with nothing recorded.
    @Test(arguments: [
        "They may chew and swallow aspirin now.", "Aspirin can be chewed now.", "If alert, a pill may be taken.",
        // A negation that isn't on the verb takes nothing back.
        "Don't wait to give aspirin.", "If not allergic they should chew aspirin.", "If there is no allergy they may chew aspirin now.",
        "Offer them an aspirin, if no allergy.", "Give them their epinephrine.", "Give them nitroglycerin.", "Have them use their EpiPen now.",
    ])
    func aPhraseCantAdviseAMedicineHowever(text: String) throws {
        #expect(TranscriptValidator.check(text, profile: .awake).isEmpty)
        try expectRefused("phrase advises a medicine: demo_line") { module in
            module["phrases"] = [phrase("demo_ask"), phrase("demo_line", text)]
        }
    }

    /// Taking one back is what the shipped steps say.
    @Test(arguments: [
        "Do not give aspirin. Wait for EMS.", "No aspirin. Wait for EMS.", "Any aspirin allergy, injury, doctor's warning, or not fully alert?",
        "Never let them take aspirin.", "Tell them not to take aspirin.", "Aspirin must not be given.",
    ])
    func aPhraseMaySayNoAspirin(text: String) {
        #expect(!BundleValidator.advisesMedicine(text))
    }

    /// Word for word, so a bad file can't keep the id and change the amount.
    @Test func theDoseExceptionIsTheApprovedText() throws {
        try expectRefused("phrase breaks the dose rule: aspirin_give") { module in
            module["phrases"] = [phrase("demo_ask"), phrase("demo_line"), phrase("aspirin_give", "Chew and swallow 650 mg of aspirin.")]
        }
    }

    @Test func aModuleCantAllowPPGOrPadZones() throws {
        try expectRefused("allows_ppg: demo_call") { changeState(1, in: &$0) { $0["allows_ppg"] = true } }
        try expectRefused("pad zones: demo_call") { changeState(1, in: &$0) { $0["overlay"] = "pad_zones" } }
    }

    @Test func anAwakeHintHasToBeAResourceAndAModulesOwnLine() throws {
        try expectRefused("not a resource: defibrillator") { $0["awake_resource_hints"] = ["defibrillator": "demo_line"] }
        try expectRefused("dangling hint nowhere") { $0["awake_resource_hints"] = ["aed": "nowhere"] }
        try expectRefused("core phrase on an awake path: aed_spotted") { $0["awake_resource_hints"] = ["aed": "aed_spotted"] }
        try expectRefused("dose outside an aspirin step") {
            $0["phrases"] = [phrase("demo_ask"), phrase("demo_line"), phrase("aspirin_give", doseText)]
            $0["awake_resource_hints"] = ["aed": "aspirin_give"]
        }
    }

    @Test func aSecondModuleCantTakeAnAwakeHint() throws {
        var first = goodModule()
        first["awake_resource_hints"] = ["aed": "demo_line"]
        var later = laterModule()
        later["awake_resource_hints"] = ["aed": "later_line"]
        let merged = try loadBundle().merging(modules: [try source(first), try source(later, id: "later")], pack: try shippedPack())
        #expect(merged.moduleFailures.map(\.id) == ["later"])
        #expect(merged.moduleFailures.first?.reason == "hint collision: aed")
        #expect(merged.awakeResourceHints == ["aed": "demo_line"])
    }

    @Test func aTimeoutsPhraseHasToExist() throws {
        try expectRefused("dangling phrase nowhere: demo_call") {
            changeState(1, in: &$0) { $0["timeout"] = ["seconds": 10, "to": "demo_wait", "phrases": ["nowhere"]] }
        }
    }

    @Test func aTimeoutMayNotBorrowCoresPhrases() throws {
        try expectRefused("core phrase on an awake path: hands_center") {
            changeState(1, in: &$0) { $0["timeout"] = ["seconds": 10, "to": "demo_wait", "phrases": ["hands_center"]] }
        }
    }

    @Test func aTimeoutCantLandOnTriage() throws {
        try expectRefused("timeout into a human-only state: triage to triage") {
            changeState(0, in: &$0) { $0["timeout"] = ["seconds": 5, "to": "triage"] }
        }
    }

    @Test(arguments: [0, -1])
    func aTimerMustTakeSomeTime(seconds: Int) throws {
        try expectRefused("timeout not above 0: triage") { changeState(0, in: &$0) { $0["timeout"] = ["seconds": seconds, "to": "demo_call"] } }
        try expectRefused("repeat not above 0: demo_wait") {
            changeState(2, in: &$0) { $0["repeating"] = [["phrase": "demo_line", "every_seconds": seconds]] }
        }
    }

    // MARK: - Whose phrases

    @Test func anAwakeStateCantBorrowACPRPhrase() throws {
        let reason = "core phrase on an awake path: keep_going"
        try expectRefused(reason) { changeState(1, in: &$0) { $0["entry_phrases"] = ["keep_going"] } }
        try expectRefused(reason) { changeState(1, in: &$0) { $0["allowed_say"] = ["keep_going"] } }
        try expectRefused(reason) { changeState(2, in: &$0) { $0["repeating"] = [["phrase": "keep_going", "every_seconds": 30]] } }
        try expectRefused(reason) { addEdge(edge("human.back", to: "demo_wait", extra: ["phrases": ["keep_going"]]), toState: 1, in: &$0) }
        try expectRefused(reason) {
            $0["entries"] = [["state": "demo_wait", "edge": edge("human.back", to: "demo_call", extra: ["phrases": ["keep_going"]])]]
        }
        // A correction plays on a flag, with no tap.
        try expectRefused("core phrase on an awake path: start_compressions") { $0["awake_correction_phrases"] = ["dose": "start_compressions"] }
    }

    /// A model line saying a dose would otherwise play the dose, with no tap and nothing recorded.
    @Test func aCorrectionCantBeTheDose() throws {
        try expectRefused("dose outside an aspirin step: aspirin_give") { module in
            module = withDose { _ in }
            addEdge(edge("human.yes", to: "demo_aspirin"), toState: 1, in: &module)
            module["awake_correction_phrases"] = ["dose": "aspirin_give"]
        }
    }

    @Test func anAwakeStateMayPromptACallAndBorrowFromAnEarlierModule() throws {
        var first = goodModule()
        changeState(1, in: &first) { $0["entry_phrases"] = ["call_911", "demo_line"] }
        var later = laterModule()
        changeState(0, in: &later) { $0["entry_phrases"] = ["demo_line", "later_line"] }
        let merged = try loadBundle().merging(modules: [try source(first, id: "first"), try source(later, id: "later")], pack: try shippedPack())
        #expect(merged.moduleFailures.isEmpty, "\(merged.moduleFailures)")
    }

    @Test func aFlowIDMustSayPossible() throws {
        try expectRefused("flow id must start with possible_") {
            $0["flow"] = ["id": "heart_attack", "title": "Heart attack", "rule": "Chest pain.", "sources": ["Fixture"]]
            changeState(1, in: &$0) { $0["flow"] = "heart_attack" }
            changeState(2, in: &$0) { $0["flow"] = "heart_attack" }
        }
        try expectRefused("undeclared flow") { changeState(1, in: &$0) { $0["flow"] = "heart_attack" } }
    }

    /// The why panel shows the title as written.
    @Test func aFlowTitleMustSayPossible() throws {
        try expectRefused("flow title must say possible: Heart attack") {
            $0["flow"] = ["id": "possible_demo", "title": "Heart attack", "rule": "Chest pain.", "sources": ["Fixture"]]
        }
    }

    @Test func anEntryThatLowersUrgencyIsRefused() throws {
        try expectRefused("cannot_lower_urgency") {
            $0["entries"] = [graft("demo_call", "model.other_concern", to: "triage")]
        }
    }

    @Test func aModelEdgeThatLowersUrgencyIsRefused() throws {
        try expectRefused("cannot_lower_urgency") { addEdge(edge("model.other_concern", to: "triage"), toState: 1, in: &$0) }
    }

    @Test func aTimeoutThatLowersUrgencyIsRefused() throws {
        try expectRefused("cannot_lower_urgency") { changeState(1, in: &$0) { $0["timeout"] = ["seconds": 10, "to": "triage"] } }
        try expectRefused("cannot_lower_urgency") {
            changeState(1, in: &$0) { state in
                state["timeout"] = ["seconds": 10, "to": "demo_wait", "if_breaths_at_least": ["count": 2, "to": "triage"]]
            }
        }
    }

    @Test func anAwakeStateCantTimeOutIntoCPR() throws {
        try expectRefused("timeout into the arrest path") { changeState(1, in: &$0) { $0["timeout"] = ["seconds": 10, "to": "call_911"] } }
    }

    @Test func aRedirectThatLowersUrgencyIsRefused() throws {
        try expectRefused("cannot_lower_urgency") {
            changeState(2, in: &$0) { $0["after_pads"] = "responsive_patient" }
            addEdge(edge("model.other_concern", to: "demo_wait"), toState: 1, in: &$0)
        }
    }

    /// Urgency is what makes the injected edges pass, so a state too urgent for them can't load.
    @Test func aStateAboveTheCollapseEdgesIsRefused() throws {
        try expectRefused("cannot_lower_urgency: model.unresponsive") { changeState(2, in: &$0) { $0["urgency"] = 3 } }
    }

    @Test func aModelEdgeOutOfAnArrestStateIsRefused() throws {
        for id in ["intake_responsive", "watch_breathing", "call_911", "compressions", "aed_analyze"] {
            try expectRefused("arrest_path_locked") { $0["entries"] = [graft(id, "model.chest_pain", to: "demo_call")] }
        }
    }

    @Test func aHumanEntryOnAnArrestStateIsRefused() throws {
        try expectRefused("arrest_path_locked") { $0["entries"] = [graft("compressions", "human.triage_open", to: "triage")] }
    }

    /// `refusal` passes a card going up, and the plan keeps model routing to the awake states. A card
    /// takes no entry but the one tap, so that's what refuses it first.
    @Test func aModelEdgeOutOfACardIsRefused() throws {
        try expectRefused("core entry can't graft: responsive_patient model.chest_pain") {
            $0["entries"] = [graft("responsive_patient", "model.chest_pain", to: "demo_call")]
        }
    }

    @Test(arguments: ["responsive", "breathing_normally", "patient_moving", "ems_arrived"])
    func aModelEdgeOnALoweringFindingIsRefused(finding: String) throws {
        try expectRefused("cannot_lower_urgency: model.\(finding)") { addEdge(edge("model.\(finding)", to: "demo_wait"), toState: 1, in: &$0) }
    }

    @Test func aModuleCantHideAnInjectedEdge() throws {
        for key in ["human.start_cpr", "human.patient_unresponsive", "human.ems_arrived", "human.not_adult", "human.not_this", "model.unresponsive", "model.not_breathing", "model.abnormal_breathing"] {
            try expectRefused("repeats edge \(key)") { addEdge(edge(key, to: "demo_wait"), toState: 1, in: &$0) }
            try expectRefused("repeats edge \(key)") { $0["entries"] = [graft("demo_call", key, to: "demo_wait")] }
        }
    }

    @Test func aRepeatedKeyIsRefused() throws {
        try expectRefused("repeats edge human.back") {
            $0["entries"] = [graft("demo_wait", "human.back", to: "triage"), graft("demo_wait", "human.back", to: "demo_call")]
        }
        // On a card, the one-entry rule gets there first.
        try expectRefused("core entry can't graft: responsive_patient human.start_cpr") { $0["entries"] = [graft("responsive_patient", "human.start_cpr", to: "triage")] }
    }

    /// On a state an earlier module owns, `transition(on:)` would keep that module's edge and hide this one.
    @Test func aLaterModuleCantRepeatAKeyOnAStateItDoesntOwn() throws {
        var later = laterModule()
        later["entries"] = [graft("triage", "human.triage_chest", to: "later_start")]
        let merged = try loadBundle().merging(modules: [try source(goodModule(), id: "first"), try source(later, id: "later")], pack: try shippedPack())
        #expect(merged.moduleFailures.map(\.id) == ["later"])
        #expect(merged.moduleFailures.first?.reason == "repeats edge human.triage_chest: triage")
        #expect(merged.definition.states.first { $0.id == "triage" }?.transitions.filter { $0.on == "human.triage_chest" }.count == 1)
    }

    @Test func onlyHumanYesCanMoveInCore() throws {
        try expectRefused("core edge can't move") { $0["replaced_edges"] = [graft("intake_breathing", "human.no", to: "triage")] }
        try expectRefused("core edge can't move") { $0["replaced_edges"] = [graft("compressions", "human.ems_arrived", to: "triage")] }
        try expectRefused("core edge can't move") { $0["replaced_edges"] = [graft("intake_responsive", "model.not_breathing", to: "demo_call")] }
        try expectRefused("core edge can't move") { $0["replaced_edges"] = [graft("intake_responsive", "human.yes", to: "demo_call")] }
        try expectRefused("core edge can't move") { $0["replaced_edges"] = [graft("responsive_patient", "human.start_cpr", to: "triage")] }
    }

    @Test func aLaterModuleCantReplaceAnInjectedEdge() throws {
        var later = laterModule()
        later["replaced_edges"] = [graft("triage", "model.unresponsive", to: "later_start")]
        let merged = try loadBundle().merging(modules: [try source(goodModule(), id: "first"), try source(later, id: "later")], pack: try shippedPack())
        #expect(merged.moduleFailures.first?.reason.contains("replaces injected edge") == true)
        #expect(merged.definition.states.first { $0.id == "triage" }?.transition(on: "model.unresponsive")?.to == "intake_breathing")
    }

    @Test func aModuleCantOpenSpeechOnAStateItDoesntOwn() throws {
        try expectRefused("opens speech") { $0["open_states"] = ["compressions"] }
        try expectRefused("opens speech") { $0["open_states"] = ["nowhere"] }
    }

    @Test func aModuleCantRewordACorrection() throws {
        try expectRefused("correction collision: pulse_check") { $0["correction_phrases"] = ["pulse_check": "demo_line"] }
    }

    // MARK: - Phrase rules

    @Test func aPhraseMustFitAFiveSecondClip() throws {
        let fourteen = Array(repeating: "word", count: 14).joined(separator: " ")
        var fits = goodModule()
        fits["phrases"] = [phrase("demo_ask", fourteen), phrase("demo_line")]
        let merged = try loadBundle().merging(modules: [try source(fits)], pack: try shippedPack())
        #expect(merged.moduleFailures.isEmpty)

        try expectRefused("phrase over 14 words: demo_ask") { $0["phrases"] = [phrase("demo_ask", fourteen + " more"), phrase("demo_line")] }
    }

    @Test func everythingNeedsACitation() throws {
        try expectRefused("phrase has no citation: demo_ask") { $0["phrases"] = [phrase("demo_ask", citation: ""), phrase("demo_line")] }
        try expectRefused("state has no citation: demo_call") { changeState(1, in: &$0) { $0["citation"] = "" } }
    }

    // MARK: - Between modules

    @Test func aCollisionWithAnEarlierModuleDropsOnlyTheLaterOne() throws {
        let core = try loadBundle()
        let first = core.merging(modules: [try source(goodModule(), id: "first")], pack: try shippedPack())

        var stateCollision = laterModule()
        stateCollision["states"] = [state("demo_call", urgency: 1, flow: "possible_later", entry: ["later_line"])]
        stateCollision["entries"] = [[String: Any]]()
        var phraseCollision = laterModule()
        phraseCollision["phrases"] = [phrase("later_line"), phrase("demo_line")]
        var flowCollision = laterModule()
        flowCollision["flow"] = goodModule()["flow"]
        flowCollision["states"] = [state("later_start", urgency: 1, entry: ["later_line"])]

        for (bad, reason) in [(stateCollision, "state id collision"), (phraseCollision, "phrase id collision"), (flowCollision, "flow id collision")] {
            let merged = core.merging(modules: [try source(goodModule(), id: "first"), try source(bad, id: "second")], pack: try shippedPack())
            #expect(merged.moduleFailures.map(\.id) == ["second"])
            #expect(merged.moduleFailures.first?.reason.contains(reason) == true, "\(reason)")
            #expect(merged.definition == first.definition)
            #expect(merged.phrases == first.phrases)
            expectRuns(merged)
        }
    }

    @Test func entriesFromADroppedModuleAreNotApplied() throws {
        let core = try loadBundle()
        let first = core.merging(modules: [try source(goodModule(), id: "first")], pack: try shippedPack())
        var bad = laterModule()
        changeState(0, in: &bad) { $0["metronome"] = "on" }
        let merged = core.merging(modules: [try source(goodModule(), id: "first"), try source(bad, id: "second")], pack: try shippedPack())
        #expect(merged.definition == first.definition)
        #expect(merged.definition.states.first { $0.id == "triage" }?.transition(on: "human.triage_limb") == nil)
    }

    @Test func aFlowOnADroppedTriageIsDroppedToo() throws {
        let core = try loadBundle()
        let merged = core.merging(modules: [
            ModuleSource(id: "first", data: Data("not json".utf8)),
            try source(laterModule(), id: "second"),
        ], pack: try shippedPack())

        #expect(merged.moduleFailures.map(\.id) == ["first", "second"])
        #expect(merged.moduleFailures.last?.reason.contains("entry on unknown state: triage") == true)
        #expect(merged.definition == core.definition)
        #expect(merged.definition.states.first { $0.id == "intake_responsive" }?.transition(on: "human.yes")?.to == "responsive_patient")
    }

    @Test func moduleOrderIsFixedByTheCaller() throws {
        let merged = try loadBundle().merging(modules: [
            try source(laterModule(), id: "second"),
            try source(goodModule(), id: "first"),
        ], pack: try shippedPack())

        #expect(merged.moduleFailures.map(\.id) == ["second"], "it points at a module that hasn't loaded")
        #expect(merged.flows.map(\.id) == ["possible_demo"])
    }

    @Test func modulesStackInOrder() throws {
        let merged = try loadBundle().merging(modules: [
            try source(goodModule(), id: "first"),
            try source(laterModule(), id: "second"),
        ], pack: try shippedPack())

        #expect(merged.moduleFailures.isEmpty)
        #expect(merged.flows.map(\.id) == ["possible_demo", "possible_later"])
        #expect(merged.definition.states.first { $0.id == "triage" }?.transition(on: "human.triage_limb")?.to == "later_start")
        #expect(merged.definition.states.first { $0.id == "later_start" }?.transition(on: "human.not_this")?.to == "triage")
        expectRuns(merged)
    }

    // MARK: - Knowledge pack

    @Test(arguments: [
        nil, "not json", "{}", #"{"version":"v","status":"DRAFT","topics":[]}"#,
        #"{"version":"v","status":"DRAFT","topics":[{"id":"a","title":"A","source":"","text":"B"}]}"#,
        #"{"version":"v","status":"DRAFT","topics":[{"id":"a","title":"A","source":"S","text":""}]}"#,
        #"{"version":"v","status":"DRAFT","topics":[{"id":"a","title":"A","source":"S","text":" \n "}]}"#,
        #"{"version":"v","status":"DRAFT","topics":[{"id":"a","title":"A","source":" ","text":"B"}]}"#,
    ])
    func noPackClosesVoiceInEveryAwakeState(pack: String?) throws {
        let core = try loadBundle()
        let merged = core.merging(modules: [try source(goodModule())], pack: pack.map { Data($0.utf8) })

        #expect(merged.knowledgePack == nil)
        #expect(merged.moduleFailures.map(\.id) == [KnowledgePack.id])
        #expect(merged.moduleFailures.first?.reason == (pack == nil ? "missing" : "invalid"))
        #expect(merged.definition.speechGate.openStates == core.definition.speechGate.openStates)

        // The flows still run by local phrases.
        let engine = ProtocolEngine(bundle: merged)
        var session = Session(engine: engine)
        session.human(.yes)
        #expect(session.state.stateID == "triage")
        #expect(session.phrases == ["demo_ask"])
        #expect(!engine.policy(for: session.state, at: session.now).modelSpeechOpen)
        session.human(.triageChest)
        #expect(session.state.stateID == "demo_call")
        #expect(!engine.policy(for: session.state, at: session.now).modelSpeechOpen)
    }

    @Test func noPackLeavesArrestAsItIs() throws {
        let core = try loadBundle()
        let merged = core.merging(modules: [], pack: nil)
        #expect(merged.definition == core.definition)
        #expect(merged.phrases == core.phrases)
        #expect(merged.moduleFailures == [ModuleFailure(id: KnowledgePack.id, reason: "missing")])
        expectRuns(merged)
    }

    // MARK: - What ships

    /// The modules arrive over later steps. Only one with no file yet may be missing, and a file
    /// the manifest doesn't name would never load, so that fails here too.
    @Test func theShippedFilesMerge() throws {
        let core = try loadBundle()
        let merged = try loadMergedBundle()
        let folder = repoRoot().appendingPathComponent("clinical/modules").path
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let present = Set(files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(".json".count)) })

        #expect(merged.knowledgePack != nil)
        #expect(present.isSubset(of: ScenarioModule.manifest), "\(present)")
        #expect(Set(merged.moduleFailures.map(\.id)) == Set(ScenarioModule.manifest).subtracting(present), "\(merged.moduleFailures)")
        #expect(merged.moduleFailures.allSatisfy { $0.reason == "missing" }, "\(merged.moduleFailures)")
        let moved = "intake_responsive"
        #expect(arrestStates(merged).filter { $0.id != moved } == arrestStates(core).filter { $0.id != moved })
        #expect(Set(core.definition.speechGate.openStates).isSubset(of: merged.definition.speechGate.openStates))
        expectRuns(merged)
    }

    /// Text the plan holds the pack to. The loader only checks it's there.
    @Test func theShippedPackKeepsItsRules() throws {
        let pack = try #require(KnowledgePack(data: try shippedPack()))
        #expect(pack.reviewer != nil || pack.status == "DRAFT")
        for topic in pack.topics {
            #expect(topic.text.split(separator: " ").count <= 120, "\(topic.id)")
            #expect(topic.text.range(of: #"\d\s*mg\b|milligram"#, options: [.regularExpression, .caseInsensitive]) == nil, "\(topic.id)")
        }
    }

    // MARK: - The core check, moved here from the app

    @Test func theCoreCheckStillRefusesWhatItDid() throws {
        let core = try loadBundle()
        #expect(BundleValidator.isRunnable(core))

        var duplicate = core
        duplicate.definition.states.append(core.definition.states[0])
        #expect(!BundleValidator.isRunnable(duplicate))

        var noStart = core
        noStart.definition.initialState = "nowhere"
        #expect(!BundleValidator.isRunnable(noStart))

        var dangling = core
        dangling.definition.states[0].transitions[0].to = "nowhere"
        #expect(!BundleValidator.isRunnable(dangling))

        var noPhrase = core
        noPhrase.phrases.phrases.removeAll { $0.id == "start_compressions" }
        #expect(!BundleValidator.isRunnable(noPhrase))
    }
}
