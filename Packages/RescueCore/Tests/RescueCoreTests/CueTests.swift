import Foundation
import Testing
@testable import RescueCore

private var padCue: [String: Any] {
    ["phrase": "demo_pad_line", "material": "towel", "body": "injured_limb", "placement": "under", "callout": "Pad under · Towel"]
}

private var glovesCue: [String: Any] { ["phrase": "demo_gloves_line", "material": "gloves", "callout": "Put on · Gloves"] }

/// A flow with one pinned step that points at a towel and gloves. Each bad case breaks one thing in it.
private func cueModule() -> [String: Any] {
    [
        "version": "fixture.v1",
        "status": "DRAFT",
        "flow": ["id": "possible_demo", "title": "Possible demo", "rule": "A demo finding in an awake adult.", "sources": ["Fixture"]],
        "states": [
            [
                "id": "triage", "kind": "triage", "urgency": 0, "entry_phrases": ["demo_ask"], "metronome": "off",
                "frame_uplink": false, "allowed_say": [String](), "after_pads": "responsive_patient", "citation": "Fixture",
                "transitions": [["on": "human.triage_limb", "to": "demo_pad"]],
            ],
            [
                "id": "demo_pad", "kind": "flow", "urgency": 1, "flow": "possible_demo", "entry_phrases": ["demo_pad_line"],
                "metronome": "off", "frame_uplink": false, "locate_materials": true, "overlay": "injury_site",
                "allowed_say": ["demo_gloves_line"], "cues": [padCue, glovesCue], "citation": "Fixture",
                "transitions": [["on": "human.done", "to": "demo_wait"]],
            ],
            [
                "id": "demo_wait", "kind": "flow", "urgency": 1, "flow": "possible_demo", "entry_phrases": ["demo_wait_line"],
                "metronome": "off", "frame_uplink": false, "allowed_say": [String](), "transitions": [[String: Any]](), "citation": "Fixture",
            ],
        ],
        "phrases": [
            ["id": "demo_ask", "text": "A short fixture line.", "citation": "Fixture"],
            ["id": "demo_pad_line", "text": "Don't straighten it. Pad under it with a towel.", "citation": "Fixture"],
            ["id": "demo_gloves_line", "text": "Put gloves on if they're in reach.", "citation": "Fixture"],
            ["id": "demo_wait_line", "text": "A short fixture line.", "citation": "Fixture"],
        ],
        "replaced_edges": [["state": "intake_responsive", "edge": ["on": "human.yes", "to": "triage"]]],
        "open_states": ["triage"],
    ]
}

private func merge(_ module: [String: Any]) throws -> ProtocolBundle {
    let source = ModuleSource(id: "fixture", data: try JSONSerialization.data(withJSONObject: module))
    let pack = try Data(contentsOf: repoRoot().appendingPathComponent("clinical/\(KnowledgePack.id).json"))
    return try loadBundle().merging(modules: [source], pack: pack)
}

/// The pinned step, changed.
private func withPadStep(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
    var module = cueModule()
    var states = module["states"] as! [[String: Any]]
    change(&states[1])
    module["states"] = states
    return module
}

private func withCue(_ fields: [String: Any]) -> [String: Any] {
    withPadStep { $0["cues"] = [fields] }
}

private func expectRefused(_ module: [String: Any], because reason: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let core = try loadBundle()
    let merged = try merge(module)
    let got = merged.moduleFailures.first?.reason ?? "loaded"
    #expect(merged.moduleFailures.count == 1, sourceLocation: sourceLocation)
    #expect(got.contains(reason), "refused for: \(got)", sourceLocation: sourceLocation)
    #expect(merged.definition == core.definition, "nothing of it merged", sourceLocation: sourceLocation)
}

private func session(_ bundle: ProtocolBundle) -> Session { Session(engine: ProtocolEngine(bundle: bundle)) }

private func cues(in effects: [RescueEffect]) -> [[Cue]] {
    effects.compactMap { if case let .cues(cues) = $0 { cues } else { nil } }
}

@Suite struct CueTests {
    // MARK: - Decoding

    @Test func coreDecodesWithNoCuesAndNoLocate() throws {
        for state in try loadBundle().definition.states {
            #expect(state.cues.isEmpty, "\(state.id)")
            #expect(!state.locateMaterials, "\(state.id)")
        }
    }

    @Test func aCueDecodesEveryField() throws {
        let data = try JSONSerialization.data(withJSONObject: padCue)
        let cue = try ProtocolBundle.clinicalDecoder().decode(Cue.self, from: data)
        #expect(cue == Cue(phrase: "demo_pad_line", material: .towel, body: .injuredLimb, placement: .under, callout: "Pad under · Towel"))
        #expect(cue.unknownValues.isEmpty)

        let again = try ProtocolBundle.clinicalDecoder().decode(Cue.self, from: JSONEncoder().encode(cue))
        #expect(again == cue)
    }

    @Test func onlyThePhraseIsRequired() throws {
        let cue = try ProtocolBundle.clinicalDecoder().decode(Cue.self, from: Data(#"{"phrase":"x"}"#.utf8))
        #expect(cue == Cue(phrase: "x"))
        #expect(throws: DecodingError.self) { try ProtocolBundle.clinicalDecoder().decode(Cue.self, from: Data(#"{"material":"towel"}"#.utf8)) }
    }

    /// One wrong word would otherwise drop the whole flow as "does not decode", with nothing to say why.
    @Test(arguments: [
        ("body", "upper_back", "cue body upper_back is not known"),
        ("body", "injury_limb", "cue body injury_limb is not known"),
        ("placement", "beside", "cue placement beside is not known"),
        ("material", "clothing", "cue material clothing is not known"),
    ])
    func anUnknownValueIsRefusedByName(field: String, value: String, reason: String) throws {
        var fields = padCue
        fields[field] = value
        try expectRefused(withCue(fields), because: reason)
    }

    // MARK: - What the loader refuses

    @Test func theFixtureMerges() throws {
        let merged = try merge(cueModule())
        #expect(merged.moduleFailures.isEmpty, "\(merged.moduleFailures)")
        let pad = try #require(merged.definition.states.first { $0.id == "demo_pad" })
        #expect(pad.cues.map(\.callout) == ["Pad under · Towel", "Put on · Gloves"])
        #expect(pad.locateMaterials)
    }

    @Test func aCuePointsFromOneOfItsStepsOwnLines() throws {
        var fields = padCue
        fields["phrase"] = "demo_ask"
        try expectRefused(withCue(fields), because: "cue phrase is not this step's line demo_ask: demo_pad")
    }

    @Test func aCueCannotHangOffABorrowedLine() throws {
        let module = withPadStep {
            $0["allowed_say"] = ["demo_gloves_line", "assign_helper"]
            $0["cues"] = [["phrase": "assign_helper"]]
        }
        try expectRefused(module, because: "cue on a phrase the module doesn't own assign_helper")
    }

    @Test(arguments: [
        "Pad under · Blanket",
        "Pad · Towel here",
        "Wrap · Towel",
    ])
    func everyCalloutWordIsInItsPhrase(callout: String) throws {
        var fields = padCue
        fields["callout"] = callout
        try expectRefused(withCue(fields), because: "callout word not in its phrase")
    }

    @Test func aCalloutNamesItsMaterial() throws {
        var fields = padCue
        fields["callout"] = "Pad under it"
        try expectRefused(withCue(fields), because: "callout doesn't name the towel")
    }

    @Test(arguments: ["Don't pad under it · Towel", "·", ""])
    func aCalloutIsOneToFourWords(callout: String) throws {
        var fields = padCue
        fields["callout"] = callout
        try expectRefused(withCue(fields), because: "callout not 1 to 4 words")
    }

    /// The middle dot and punctuation aren't words, so these fit.
    @Test(arguments: ["Pad under · Towel", "Pad it under: towel.", "TOWEL", "Don't · Towel"])
    func punctuationIsNotAWord(callout: String) throws {
        var fields = padCue
        fields["callout"] = callout
        #expect(try merge(withCue(fields)).moduleFailures.isEmpty, "\(callout)")
    }

    /// Words from a clean line can still drop its "don't".
    @Test func aCalloutCannotDropTheNegation() throws {
        var fields = padCue
        fields["callout"] = "Straighten it · Towel"
        try expectRefused(withCue(fields), because: "callout breaks a phrase rule")
    }

    @Test func aCalloutNeedsAMaterial() throws {
        try expectRefused(withCue(["phrase": "demo_pad_line", "callout": "Pad under"]), because: "callout with no material")
    }

    @Test func aMaterialIsOneItsLineNames() throws {
        try expectRefused(withCue(["phrase": "demo_pad_line", "material": "pillow"]), because: "cue phrase doesn't name the pillow demo_pad_line")
    }

    @Test func aBodyNeedsThePin() throws {
        let module = withPadStep { $0["overlay"] = nil }
        try expectRefused(module, because: "cue body without the pin: demo_pad")
    }

    @Test func aPlacementNeedsABody() throws {
        var fields = padCue
        fields["body"] = nil
        try expectRefused(withCue(fields), because: "cue placement with no body")
    }

    @Test func locatingNeedsSomethingToFind() throws {
        let module = withPadStep { $0["cues"] = [["phrase": "demo_pad_line", "body": "injury_site"]] }
        try expectRefused(module, because: "locate_materials with nothing to find: demo_pad")
    }

    /// A step that names nothing itself may still look for what its flow's later steps point at.
    @Test func aStepMayLocateForItsFlow() throws {
        var module = cueModule()
        var states = module["states"] as! [[String: Any]]
        states[2]["locate_materials"] = true
        module["states"] = states
        let merged = try merge(module)
        #expect(merged.moduleFailures.isEmpty, "\(merged.moduleFailures)")
    }

    @Test func coreStatesCarryNoCues() throws {
        var cued = try loadBundle()
        cued.definition.states[0].cues = [Cue(phrase: try #require(cued.definition.states[0].entryPhrases.first))]
        #expect(!BundleValidator.isRunnable(cued))

        var locating = try loadBundle()
        locating.definition.states[0].locateMaterials = true
        #expect(!BundleValidator.isRunnable(locating))

        #expect(BundleValidator.isRunnable(try loadBundle()))
    }

    // MARK: - The engine

    @Test func enteringAStepSendsItsCuesNextToTheOverlay() throws {
        let bundle = try merge(cueModule())
        var session = session(bundle)
        session.human(.yes)
        #expect(cues(in: session.effects) == [[]], "triage clears whatever came before")

        session.human(.triageLimb)
        let pad = try #require(bundle.definition.states.first { $0.id == "demo_pad" })
        #expect(cues(in: session.effects) == [pad.cues])
        let overlay = try #require(session.effects.firstIndex(of: .overlay(.injurySite)))
        #expect(session.effects[overlay + 1] == .cues(pad.cues))

        session.human(.done)
        #expect(session.state.stateID == "demo_wait")
        #expect(cues(in: session.effects) == [[]])
    }

    @Test func everyEntryOnTheArrestPathClearsToo() throws {
        var session = Session(engine: ProtocolEngine(bundle: try loadBundle()))
        #expect(cues(in: session.effects) == [[]])
        session.human(.startCpr)
        #expect(cues(in: session.effects) == [[]])
    }

    @Test func theLocatePermissionFollowsTheStepAndTheCall() throws {
        let engine = ProtocolEngine(bundle: try merge(cueModule()))
        var state = engine.start(at: 0).state
        for (id, locates) in [("demo_pad", true), ("demo_wait", false), ("triage", false), ("intake_responsive", false)] {
            state.stateID = id
            #expect(engine.policy(for: state, at: 0).frameLocate == locates, "\(id)")
            #expect(engine.materialsToLocate(for: state, at: 0) == (locates ? [.towel, .gloves] : []), "\(id)")
        }
        state.stateID = "demo_pad"
        state.callActive = true
        #expect(!engine.policy(for: state, at: 0).frameLocate)
        #expect(engine.materialsToLocate(for: state, at: 0).isEmpty)
    }

    @Test func aCueOnlyLineTakesNoSay() throws {
        var session = session(try merge(cueModule()))
        session.human(.yes)
        session.human(.triageLimb)
        session.model(.say(phraseID: "demo_gloves_line"))
        #expect(session.phrases.isEmpty)
        #expect(session.entries(.proposalRejected).last?.detail.hasSuffix(SafetyGate.RejectReason.phraseNotAllowed.rawValue) == true)
    }

    // MARK: - What ships

    private let support = [
        Cue(phrase: "limb_support", material: .towel, body: .injuredLimb, placement: .under, callout: "Pad under · Towel"),
        Cue(phrase: "limb_support", material: .pillow, body: .injuredLimb, placement: .under, callout: "Pad under · Pillow"),
    ]

    @Test func theShippedCuesAreThese() throws {
        let bundle = try loadMergedBundle()
        #expect(bundle.moduleFailures.isEmpty, "\(bundle.moduleFailures)")
        let cued = Dictionary(uniqueKeysWithValues: bundle.definition.states.filter { !$0.cues.isEmpty }.map { ($0.id, $0.cues) })
        #expect(cued == [
            "limb_splint": support,
            // The rescuer pads the limb once the step has moved on, so the marks stay.
            "limb_wait": support,
            "limb_danger": [
                Cue(phrase: "limb_danger_care", material: .towel, body: .injurySite, placement: .on, callout: "Press · Cloth"),
                Cue(phrase: "limb_gloves", material: .gloves, callout: "Put on · Gloves"),
            ],
        ])
    }

    /// The whole flow's materials from its first step, so a locate that takes seconds is in by the step
    /// that points at one.
    @Test func theBrokenBoneFlowLooksForItsMaterialsFromTheStart() throws {
        let bundle = try loadMergedBundle()
        var session = Session(engine: ProtocolEngine(bundle: bundle))
        session.human(.yes)
        #expect(session.engine.materialsToLocate(for: session.state, at: session.now).isEmpty, "triage")
        session.human(.triageLimb)
        #expect(session.state.stateID == "limb_start")
        #expect(session.engine.materialsToLocate(for: session.state, at: session.now) == [.towel, .pillow, .gloves])
        #expect(cues(in: session.effects) == [[]], "nothing to point at yet")

        session.human(.done)
        session.human(.no)
        #expect(session.state.stateID == "limb_splint")
        #expect(cues(in: session.effects) == [support])
        session.human(.done)
        #expect(cues(in: session.effects) == [support])
    }

    @Test func theHeartAttackFlowLocatesNothingNew() throws {
        let bundle = try loadMergedBundle()
        for state in bundle.definition.states where state.flow == "possible_heart_attack" {
            #expect(state.cues.isEmpty, "\(state.id)")
            #expect(!state.locateMaterials, "\(state.id)")
        }
    }
}
