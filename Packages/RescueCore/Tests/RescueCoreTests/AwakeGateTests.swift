import Foundation
import Testing
@testable import RescueCore

/// A hand-built graph, for shapes the shipped protocol doesn't have. Starts in the first state.
private func graph(_ states: [[String: Any]]) throws -> ProtocolEngine {
    let definition: [String: Any] = [
        "version": "test",
        "status": "DRAFT",
        "initial_state": states[0]["id"] as Any,
        "speech_gate": ["open_states": [String]()],
        "resource_hints": [String: String](),
        "correction_phrases": [String: String](),
        "lowering_report_phrase": "none",
        "keep_queued_phrases": [String](),
        "audio_pause_seconds": 8,
        "model_speech_hold_seconds": 8,
        "dispatcher_mic_hold_seconds": 30,
        "states": states,
    ]
    let phrases: [String: Any] = ["version": "test", "status": "DRAFT", "phrases": [String]()]
    return ProtocolEngine(bundle: try ProtocolBundle(
        protocolData: JSONSerialization.data(withJSONObject: definition),
        phrasesData: JSONSerialization.data(withJSONObject: phrases)
    ))
}

private func node(
    _ id: String,
    _ kind: StateDefinition.Kind,
    urgency: Int,
    flow: String? = nil,
    afterPads: String? = nil,
    edges: [[String: Any]] = []
) -> [String: Any] {
    var fields: [String: Any] = [
        "id": id,
        "kind": kind.rawValue,
        "urgency": urgency,
        "entry_phrases": [String](),
        "metronome": "off",
        "frame_uplink": false,
        "allowed_say": [String](),
        "transitions": edges,
        "citation": "test",
    ]
    if let flow { fields["flow"] = flow }
    if let afterPads { fields["after_pads"] = afterPads }
    return fields
}

private func edge(_ on: String, to: String, minConfidence: Confidence? = nil, cuts: Bool? = nil) -> [String: Any] {
    var fields: [String: Any] = ["on": on, "to": to]
    if let minConfidence { fields["min_confidence"] = minConfidence.rawValue }
    if let cuts { fields["cuts_phrases"] = cuts }
    return fields
}

private func definition(_ kind: StateDefinition.Kind, urgency: Int) throws -> StateDefinition {
    try #require(try graph([node("only", kind, urgency: urgency)]).definition(of: "only"))
}

private let arrestKinds: [StateDefinition.Kind] = [.intake, .watch, .setup, .cpr]
private let awakeKinds: [StateDefinition.Kind] = [.triage, .flow]

@Suite struct AwakeGateTests {
    private func shipped() throws -> ProtocolEngine {
        ProtocolEngine(bundle: try loadBundle())
    }

    // MARK: - Enums

    @Test func eachKindIsOnOneSideOrIsACard() {
        for kind in arrestKinds {
            #expect(kind.isArrestPath && !kind.isAwake, "\(kind)")
        }
        for kind in awakeKinds {
            #expect(kind.isAwake && !kind.isArrestPath, "\(kind)")
        }
        #expect(!StateDefinition.Kind.card.isArrestPath && !StateDefinition.Kind.card.isAwake)
    }

    @Test func arrestCasesAreExactlyTheOriginalNine() {
        #expect(Set(Finding.arrestCases.map(\.rawValue)) == [
            "unresponsive", "responsive", "abnormal_breathing", "not_breathing", "breathing_normally",
            "patient_moving", "ems_arrived", "dispatcher_speaking", "aed_prompting",
        ])
    }

    @Test func noNewFindingCountsAsLowering() {
        let new = Finding.allCases.filter { !Finding.arrestCases.contains($0) }
        #expect(Set(new) == [
            .chestPain, .otherHeartSigns, .limbInjury, .limbDiscolored, .heavyBleeding,
            .neckBackInjury, .choking, .otherConcern, .aspirinUnsafe,
        ])
        for finding in new { #expect(!finding.wouldLowerUrgency, "\(finding)") }
    }

    @Test func confidenceOrdersLowToHigh() {
        #expect(Confidence.low < .medium)
        #expect(Confidence.medium < .high)
        #expect(!(Confidence.high < .high))
    }

    // MARK: - Decoding

    @Test func theCoreProtocolDecodesWithEveryNewFieldEmpty() throws {
        for state in try loadBundle().definition.states {
            #expect(state.flow == nil, "\(state.id)")
            #expect(!state.kind.isAwake, "\(state.id)")
            for transition in state.transitions {
                #expect(transition.minConfidence == nil, "\(state.id) \(transition.on)")
                #expect(!transition.cutsPhrases, "\(state.id) \(transition.on)")
            }
        }
    }

    @Test func theNewFieldsDecodeFromSnakeCase() throws {
        var chest = node("chest", .flow, urgency: 2, flow: "possible_heart_attack", edges: [
            edge("model.unresponsive", to: "chest", minConfidence: .medium, cuts: true),
        ])
        chest["question"] = "aspirin_risk_reported"
        var limb = node("limb", .flow, urgency: 1)
        limb["question"] = "danger_signs"
        let engine = try graph([chest, limb])

        let decoded = try #require(engine.definition(of: "chest"))
        #expect(decoded.kind == .flow)
        #expect(decoded.flow == "possible_heart_attack")
        #expect(decoded.question == .aspirinRiskReported)
        #expect(decoded.transitions[0].minConfidence == .medium)
        #expect(decoded.transitions[0].cutsPhrases)
        #expect(engine.definition(of: "limb")?.question == .dangerSigns)
    }

    // MARK: - Refusal

    @Test func refusalChecksEachDirection() throws {
        typealias Kind = StateDefinition.Kind
        let table: [(Kind, Int, Kind, Int, SafetyGate.RejectReason?)] = [
            // Lower urgency, whatever the kinds.
            (.flow, 2, .flow, 1, .cannotLowerUrgency),
            (.flow, 2, .triage, 0, .cannotLowerUrgency),
            (.flow, 3, .intake, 2, .cannotLowerUrgency),
            (.intake, 2, .triage, 0, .cannotLowerUrgency),
            (.cpr, 4, .card, 0, .cannotLowerUrgency),
            (.cpr, 4, .watch, 1, .cannotLowerUrgency),
            // Out of the arrest path, even going up.
            (.watch, 1, .flow, 2, .arrestPathLocked),
            (.watch, 1, .triage, 1, .arrestPathLocked),
            (.intake, 2, .flow, 2, .arrestPathLocked),
            (.setup, 3, .flow, 4, .arrestPathLocked),
            (.cpr, 4, .flow, 4, .arrestPathLocked),
            (.watch, 1, .card, 2, .arrestPathLocked),
            // Up, or level, and staying on a legal side.
            (.triage, 0, .flow, 2, nil),
            (.triage, 0, .intake, 2, nil),
            (.flow, 1, .flow, 2, nil),
            (.flow, 2, .flow, 2, nil),
            (.flow, 2, .intake, 2, nil),
            (.flow, 2, .setup, 3, nil),
            (.card, 0, .intake, 2, nil),
            (.intake, 2, .intake, 2, nil),
            (.watch, 1, .setup, 3, nil),
            (.setup, 3, .cpr, 4, nil),
        ]
        for (fromKind, fromUrgency, toKind, toUrgency, expected) in table {
            let from = try definition(fromKind, urgency: fromUrgency)
            let to = try definition(toKind, urgency: toUrgency)
            #expect(
                SafetyGate.refusal(from: from, to: to) == expected,
                "\(fromKind) \(fromUrgency) to \(toKind) \(toUrgency)"
            )
        }
    }

    /// The arrest path behaves as it did before urgency was read at runtime.
    @Test func noShippedModelEdgeIsRefused() throws {
        let engine = try shipped()
        var edges = 0
        for state in engine.bundle.definition.states {
            for transition in state.transitions where transition.on.hasPrefix("model.") {
                let target = try #require(engine.definition(of: transition.to))
                #expect(SafetyGate.refusal(from: state, to: target) == nil, "\(state.id) to \(target.id)")
                if let redirect = target.afterPads {
                    let landing = try #require(engine.definition(of: redirect))
                    #expect(SafetyGate.refusal(from: state, to: landing) == nil, "\(state.id) to \(landing.id)")
                }
                edges += 1
            }
        }
        #expect(edges > 0)
    }

    @Test func aModelEdgeThatLowersUrgencyIsRejectedAtRuntime() throws {
        var session = Session(engine: try graph([
            node("chest", .flow, urgency: 2, edges: [edge("model.chest_pain", to: "calm")]),
            node("calm", .triage, urgency: 0),
        ]))
        let before = session.state
        session.modelFinding(.chestPain)
        #expect(session.state == before)
        #expect(session.entries(.proposalRejected).last?.detail == "report_finding(chest_pain, heard, high): cannot_lower_urgency")
        #expect(session.entries(.finding).isEmpty)
        #expect(session.entries(.observation).isEmpty)
    }

    @Test func aModelEdgeOutOfTheArrestPathIsRejectedAtRuntime() throws {
        var session = Session(engine: try graph([
            node("watch", .watch, urgency: 1, edges: [edge("model.not_breathing", to: "chest")]),
            node("chest", .flow, urgency: 2),
        ]))
        let before = session.state
        session.modelFinding(.notBreathing)
        #expect(session.state == before)
        #expect(session.entries(.proposalRejected).last?.detail.hasSuffix("arrest_path_locked") == true)
        #expect(session.entries(.finding).isEmpty)
    }

    /// Pads redirect the transition, so what counts is where the engine would end up.
    @Test func theCheckFollowsThePadsRedirect() throws {
        let engine = try graph([
            node("chest", .flow, urgency: 2, edges: [edge("model.unresponsive", to: "up")]),
            node("up", .flow, urgency: 3, afterPads: "calm"),
            node("calm", .triage, urgency: 0),
        ])
        var noPads = Session(engine: engine)
        noPads.modelFinding(.unresponsive)
        #expect(noPads.state.stateID == "up")

        var pads = Session(engine: engine)
        pads.state.padsOn = true
        pads.modelFinding(.unresponsive)
        #expect(pads.state.stateID == "chest")
        #expect(pads.entries(.proposalRejected).last?.detail.hasSuffix("cannot_lower_urgency") == true)
    }

    @Test func aModelEdgeToNowhereIsRejectedAndNotLoggedAsAFinding() throws {
        var session = Session(engine: try graph([
            node("chest", .flow, urgency: 2, edges: [edge("model.chest_pain", to: "missing")]),
        ]))
        session.modelFinding(.chestPain)
        #expect(session.entries(.proposalRejected).last?.detail.hasSuffix("not_applicable") == true)
        #expect(session.entries(.finding).isEmpty)
    }

    // MARK: - Evidence

    @Test(arguments: [StateDefinition.Kind.triage, .flow])
    func aFindingWithNoEdgeInAnAwakeStateIsOnlyRecorded(kind: StateDefinition.Kind) throws {
        var session = Session(engine: try graph([node("here", kind, urgency: 1)]))
        let before = session.state
        let logged = session.log.entries.count
        session.model(.reportFinding(.limbInjury, source: .seen, confidence: .medium))

        #expect(session.state == before)
        #expect(session.effects.isEmpty)
        let added = session.log.entries.dropFirst(logged)
        #expect(added.count == 1, "the observation is the only record")
        #expect(added.first?.kind == .observation)
        #expect(added.first?.source == .aiInferred)
        #expect(added.first?.detail == "limb_injury,seen,medium")
    }

    @Test(arguments: [StateDefinition.Kind.intake, .watch, .setup, .cpr, .card])
    func aFindingWithNoEdgeElsewhereIsStillNotApplicable(kind: StateDefinition.Kind) throws {
        var session = Session(engine: try graph([node("here", kind, urgency: 1)]))
        let before = session.state
        session.modelFinding(.limbInjury)
        #expect(session.state == before)
        #expect(session.entries(.observation).isEmpty)
        #expect(session.entries(.proposalRejected).last?.detail.hasSuffix("not_applicable") == true)
    }

    @Test func newFindingsChangeNothingAtIntakeOrInCPR() throws {
        let engine = try shipped()
        let new = Finding.allCases.filter { !Finding.arrestCases.contains($0) }
        for finding in new {
            var intake = Session(engine: engine)
            intake.modelFinding(finding)
            #expect(intake.state.stateID == "intake_responsive", "\(finding)")
            #expect(intake.phrases.isEmpty, "\(finding)")
            #expect(intake.entries(.observation).isEmpty, "\(finding)")

            var cpr = Session(engine: engine)
            cpr.goToCompressions()
            cpr.modelFinding(finding)
            #expect(cpr.state.stateID == "compressions", "\(finding)")
            #expect(cpr.state.metronomeOn, "\(finding)")
            #expect(cpr.phrases.isEmpty, "\(finding)")
        }
    }

    @Test func newActionsDoNothingOnTheShippedProtocol() throws {
        let engine = try shipped()
        for action in [HumanAction.triageChest, .triageLimb, .triageOther, .triageOpen, .notThis] {
            var session = Session(engine: engine)
            let before = session.state
            session.human(action)
            #expect(session.state == before, "\(action)")
            #expect(session.effects.isEmpty, "\(action)")
        }
    }

    @Test func aDispatcherReportStillHoldsTheModelInAnAwakeState() throws {
        var session = Session(engine: try graph([node("here", .triage, urgency: 0)]))
        session.modelFinding(.dispatcherSpeaking)
        #expect(session.state.modelSpeechHoldUntil != nil)
        #expect(session.state.dispatcherHeardUntil != nil)
        #expect(session.effects.contains(.flushModelAudio))
        #expect(session.entries(.finding).map(\.detail) == ["dispatcher_speaking"])
        #expect(session.entries(.observation).isEmpty)
    }

    @Test func anAEDReportStillHoldsTheModelInAnAwakeStateWithoutPausingAudio() throws {
        var session = Session(engine: try graph([node("here", .flow, urgency: 2)]))
        session.modelFinding(.aedPrompting)
        #expect(session.state.modelSpeechHoldUntil != nil)
        #expect(session.state.audioPausedUntil == nil)
        #expect(session.entries(.observation).isEmpty)
    }

    // MARK: - Confidence threshold

    @Test(arguments: [
        (Confidence.low, Confidence?.some(.medium), false),
        (.medium, .some(.medium), true),
        (.high, .some(.medium), true),
        (.medium, .some(.high), false),
        (.high, .some(.high), true),
        (.low, .some(.low), true),
        (.low, nil, true),
    ])
    func aReportBelowTheThresholdMovesNothing(reported: Confidence, threshold: Confidence?, moves: Bool) throws {
        var session = Session(engine: try graph([
            node("triage", .triage, urgency: 0, edges: [edge("model.chest_pain", to: "chest", minConfidence: threshold)]),
            node("chest", .flow, urgency: 2),
        ]))
        let before = session.state
        session.model(.reportFinding(.chestPain, source: .heard, confidence: reported))

        let detail = "chest_pain,heard,\(reported.rawValue)"
        #expect(session.entries(.observation).map(\.detail) == [detail])
        if moves {
            #expect(session.state.stateID == "chest")
            #expect(session.entries(.finding).map(\.detail) == ["chest_pain"])
        } else {
            #expect(session.state == before)
            #expect(session.effects.isEmpty)
            #expect(session.entries(.finding).isEmpty)
        }
    }

    @Test func theGateReportsEvidenceBelowTheThreshold() throws {
        let engine = try graph([
            node("triage", .triage, urgency: 0, edges: [edge("model.chest_pain", to: "chest", minConfidence: .medium)]),
            node("chest", .flow, urgency: 2),
        ])
        let start = engine.start(at: 100).state
        let decision = SafetyGate.evaluate(
            ModelProposal(
                action: .reportFinding(.chestPain, source: .seen, confidence: .low),
                stateVersion: start.version,
                issuedAt: 100
            ),
            state: start,
            definition: try #require(engine.definition(of: "triage")),
            lookup: engine.definition(of:),
            at: 100
        )
        #expect(decision == .allow(.evidence(.chestPain, source: .seen, confidence: .low)))
    }

    @Test func aRefusedEdgeIsRejectedEvenBelowItsThreshold() throws {
        var session = Session(engine: try graph([
            node("chest", .flow, urgency: 2, edges: [edge("model.chest_pain", to: "calm", minConfidence: .high)]),
            node("calm", .triage, urgency: 0),
        ]))
        session.model(.reportFinding(.chestPain, source: .heard, confidence: .low))
        #expect(session.entries(.observation).isEmpty)
        #expect(session.entries(.proposalRejected).last?.detail.hasSuffix("cannot_lower_urgency") == true)
    }

    // MARK: - Stale escalation

    private func awakeGraph(_ kind: StateDefinition.Kind) throws -> ProtocolEngine {
        try graph([
            node("start", .triage, urgency: 0, edges: [edge("human.yes", to: "here")]),
            node("here", kind, urgency: 1, edges: [
                edge("model.unresponsive", to: "breathing"),
                edge("model.not_breathing", to: "breathing"),
                edge("model.abnormal_breathing", to: "breathing"),
                edge("model.chest_pain", to: "next"),
            ]),
            node("breathing", .intake, urgency: 2),
            node("next", .flow, urgency: 2),
        ])
    }

    @Test(arguments: [
        (StateDefinition.Kind.triage, Finding.unresponsive),
        (.triage, .notBreathing),
        (.triage, .abnormalBreathing),
        (.flow, .unresponsive),
        (.flow, .notBreathing),
        (.flow, .abnormalBreathing),
    ])
    func aStaleEscalationCountsInAnAwakeState(kind: StateDefinition.Kind, finding: Finding) throws {
        var session = Session(engine: try awakeGraph(kind))
        let old = session.proposal(.reportFinding(finding, source: .heard, confidence: .high))
        session.human(.yes)
        #expect(session.state.stateID == "here")
        session.now += SafetyGate.proposalTTL
        session.send(.model(old))
        #expect(session.state.stateID == "breathing")
        #expect(session.entries(.finding).map(\.detail) == [finding.rawValue])
    }

    @Test func aStaleEscalationPastTheTTLIsExpired() throws {
        var session = Session(engine: try awakeGraph(.flow))
        let old = session.proposal(.reportFinding(.unresponsive, source: .heard, confidence: .high))
        session.human(.yes)
        session.now += SafetyGate.proposalTTL + 1
        session.send(.model(old))
        #expect(session.state.stateID == "here")
        #expect(session.entries(.proposalRejected).last?.detail.hasSuffix("expired") == true)
    }

    /// The router stamps a report on arrival, so `issuedAt` alone can't say how old its version is.
    @Test func aStaleEscalationIsBoundedByWhenItsVersionEnded() throws {
        var session = Session(engine: try awakeGraph(.flow))
        let version = session.state.version
        session.human(.yes)
        session.now += 120
        session.send(.model(ModelProposal(
            action: .reportFinding(.unresponsive, source: .heard, confidence: .high),
            stateVersion: version,
            issuedAt: session.now
        )))
        #expect(session.state.stateID == "here")
        #expect(session.entries(.proposalRejected).last?.detail.hasSuffix("expired") == true)
    }

    /// A tap can't have known about these, so one that crossed the report still loses to it.
    @Test(arguments: [Finding.heavyBleeding, .limbDiscolored, .neckBackInjury, .aspirinUnsafe])
    func aStaleDangerOrAspirinReportCountsInAnAwakeState(finding: Finding) throws {
        var session = Session(engine: try graph([
            node("start", .triage, urgency: 0, edges: [edge("human.yes", to: "here")]),
            node("here", .flow, urgency: 1, edges: [edge("model.\(finding.rawValue)", to: "next")]),
            node("next", .flow, urgency: 2),
        ]))
        let old = session.proposal(.reportFinding(finding, source: .heard, confidence: .high))
        session.human(.yes)
        session.now += 2
        session.send(.model(old))
        #expect(session.state.stateID == "next")
    }

    @Test func nothingElseStaleCountsInAnAwakeState() throws {
        let actions: [ModelProposal.Action] = [
            .reportFinding(.chestPain, source: .heard, confidence: .high),
            .reportFinding(.dispatcherSpeaking, source: .heard, confidence: .high),
            .reportResources([.aed]),
            .logEvent(.other),
        ]
        for action in actions {
            var session = Session(engine: try awakeGraph(.flow))
            let old = session.proposal(action)
            session.human(.yes)
            let before = session.state
            session.send(.model(old))
            #expect(session.state == before, "\(action)")
            #expect(session.entries(.proposalRejected).last?.detail.hasSuffix("stale_version") == true, "\(action)")
        }
    }

    /// A version that hasn't happened yet isn't stale. It's made up.
    @Test func aFutureVersionIsNotAnEscalation() throws {
        var session = Session(engine: try awakeGraph(.flow))
        session.human(.yes)
        session.send(.model(ModelProposal(
            action: .reportFinding(.unresponsive, source: .heard, confidence: .high),
            stateVersion: session.state.version + 1,
            issuedAt: session.now
        )))
        #expect(session.state.stateID == "here")
        #expect(session.entries(.proposalRejected).last?.detail.hasSuffix("stale_version") == true)
    }

    @Test(arguments: [StateDefinition.Kind.intake, .watch, .setup, .cpr, .card])
    func aStaleEscalationIsRejectedEverywhereElse(kind: StateDefinition.Kind) throws {
        var session = Session(engine: try graph([
            node("start", .triage, urgency: 0, edges: [edge("human.yes", to: "here")]),
            node("here", kind, urgency: 1, edges: [edge("model.unresponsive", to: "higher")]),
            node("higher", .setup, urgency: 3),
        ]))
        let old = session.proposal(.reportFinding(.unresponsive, source: .heard, confidence: .high))
        session.human(.yes)
        let before = session.state
        session.send(.model(old))
        #expect(session.state == before)
        #expect(session.entries(.proposalRejected).last?.detail.hasSuffix("stale_version") == true)
    }

    @Test func aStaleEscalationIsRejectedOnTheShippedArrestPath() throws {
        let walks: [(String, (inout Session) -> Void)] = [
            ("intake_breathing", { $0.human(.no) }),
            ("watch_breathing", { $0.human(.no); $0.human(.yes) }),
            ("responsive_patient", { $0.human(.yes) }),
            ("compressions", { $0.goToCompressions() }),
        ]
        for (id, walk) in walks {
            for finding in [Finding.unresponsive, .notBreathing, .abnormalBreathing] {
                var session = Session(engine: try shipped())
                let old = session.proposal(.reportFinding(finding, source: .heard, confidence: .high))
                walk(&session)
                #expect(session.state.stateID == id)
                let before = session.state
                session.send(.model(old))
                #expect(session.state == before, "\(id) \(finding)")
                #expect(session.entries(.proposalRejected).last?.detail.hasSuffix("stale_version") == true, "\(id) \(finding)")
            }
        }
    }

    // MARK: - Applying outcomes

    @Test func anAcceptedReportInAnAwakeStateIsAlsoAnObservation() throws {
        var session = Session(engine: try graph([
            node("triage", .triage, urgency: 0, edges: [edge("model.chest_pain", to: "chest")]),
            node("chest", .flow, urgency: 2, edges: [edge("model.unresponsive", to: "breathing")]),
            node("breathing", .intake, urgency: 2),
        ]))
        session.model(.reportFinding(.chestPain, source: .heard, confidence: .high))
        session.model(.reportFinding(.unresponsive, source: .seen, confidence: .low))
        #expect(session.state.stateID == "breathing")
        // The card matches these exactly.
        #expect(session.entries(.finding).map(\.detail) == ["chest_pain", "unresponsive"])
        #expect(session.entries(.observation).map(\.detail) == ["chest_pain,heard,high", "unresponsive,seen,low"])
        #expect(session.entries(.observation).allSatisfy { $0.source == .aiInferred })
    }

    @Test func anAcceptedReportOnTheShippedProtocolIsNotAnObservation() throws {
        let walks: [(inout Session) -> Void] = [{ _ in }, { $0.human(.yes) }]
        for walk in walks {
            var session = Session(engine: try shipped())
            walk(&session)
            session.modelFinding(.unresponsive)
            #expect(session.state.stateID == "intake_breathing")
            #expect(session.entries(.finding).map(\.detail) == ["unresponsive"])
            #expect(session.entries(.observation).isEmpty)
        }
    }

    @Test func anEdgeThatCutsPhrasesSilencesTheLaneAtOnce() throws {
        let engine = try graph([
            node("chest", .flow, urgency: 2, edges: [
                edge("model.unresponsive", to: "breathing", cuts: true),
                edge("human.patient_unresponsive", to: "breathing", cuts: true),
                edge("model.chest_pain", to: "next"),
                edge("human.done", to: "next"),
            ]),
            node("breathing", .intake, urgency: 2),
            node("next", .flow, urgency: 2),
        ])
        let events: [(RescueEvent, cuts: Bool)] = [
            (.human(.patientUnresponsive), true),
            (.human(.done), false),
        ]
        for (event, cuts) in events {
            var session = Session(engine: engine)
            session.send(event)
            #expect(session.effects.contains(.cutPhrases) == cuts, "\(event)")
            #expect(session.effects.contains(.dropQueuedPhrases(keeping: [])) == !cuts, "\(event)")
        }

        var collapse = Session(engine: engine)
        collapse.modelFinding(.unresponsive)
        #expect(collapse.effects.contains(.cutPhrases))
        #expect(!collapse.effects.contains(.dropQueuedPhrases(keeping: [])))

        var routine = Session(engine: engine)
        routine.modelFinding(.chestPain)
        #expect(!routine.effects.contains(.cutPhrases))
        #expect(routine.effects.contains(.dropQueuedPhrases(keeping: [])))
    }

    @Test func enteringAFlowIsLoggedOnlyWhenTheFlowChanges() throws {
        var session = Session(engine: try graph([
            node("triage", .triage, urgency: 0, edges: [
                edge("human.triage_chest", to: "chest_a"),
                edge("model.limb_injury", to: "limb"),
            ]),
            node("chest_a", .flow, urgency: 2, flow: "possible_heart_attack", edges: [
                edge("human.done", to: "chest_b"),
                edge("human.not_this", to: "triage_again"),
            ]),
            node("chest_b", .flow, urgency: 2, flow: "possible_heart_attack", edges: [
                edge("human.not_this", to: "triage_again"),
            ]),
            node("triage_again", .triage, urgency: 2, edges: [edge("model.limb_injury", to: "limb")]),
            node("limb", .flow, urgency: 2, flow: "possible_broken_bone"),
        ]))
        #expect(session.entries(.flowEntered).isEmpty)

        session.human(.triageChest)
        #expect(session.entries(.flowEntered).map(\.detail) == ["possible_heart_attack"])
        #expect(session.entries(.flowEntered).last?.source == .bystander)

        session.human(.done)
        #expect(session.state.stateID == "chest_b")
        #expect(session.entries(.flowEntered).count == 1, "same flow")

        session.human(.notThis)
        #expect(session.entries(.flowEntered).count == 1, "a state outside any flow enters none")

        session.modelFinding(.limbInjury)
        #expect(session.entries(.flowEntered).map(\.detail) == ["possible_heart_attack", "possible_broken_bone"])
        #expect(session.entries(.flowEntered).last?.source == .aiInferred)
    }

    /// A timer entering a flow isn't anyone's choice, and shouldn't read as one.
    @Test func aTimeoutIntoAFlowIsLoggedAsTheTimer() throws {
        var first = node("first", .triage, urgency: 0)
        first["timeout"] = ["seconds": 5, "to": "chest"] as [String: Any]
        var session = Session(engine: try graph([
            first,
            node("chest", .flow, urgency: 2, flow: "possible_heart_attack"),
        ]))
        session.advance(5)
        #expect(session.state.stateID == "chest")
        #expect(session.entries(.flowEntered).last?.source == .timer)
    }
}
