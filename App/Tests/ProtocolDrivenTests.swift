import Foundation
@testable import HealthAISim
import RescueCore
import Testing

@MainActor
@Suite struct ControlTests {
    /// Parks a new coordinator in a state, the way the operator panel would.
    private func fixture(in stateID: String) throws -> Fixture {
        let fixture = try Fixture()
        fixture.coordinator.beginRescue()
        if fixture.coordinator.state.stateID != stateID {
            fixture.coordinator.force(stateID: stateID)
        }
        return fixture
    }

    @Test func everyControlDoesWhatTheBundleSays() throws {
        let bundle = try shippedBundle()
        for state in bundle.definition.states {
            let expected = state.transitions.filter { $0.on.hasPrefix("human.") }
            let controls = try fixture(in: state.id).coordinator.controls

            for transition in expected {
                let name = String(transition.on.dropFirst("human.".count))
                let action = try #require(HumanAction(rawValue: name), "\(state.id): \(transition.on)")
                #expect(controls.contains { $0.action == action }, "\(state.id) doesn't offer \(name)")

                let driven = try fixture(in: state.id)
                driven.coordinator.perform(action)
                #expect(driven.coordinator.state.stateID == transition.to, "\(state.id) + \(name)")
            }

            // The only extras are the actions that change no state.
            let extras = controls.map(\.action).filter { action in
                !expected.contains { $0.on == "human.\(action.rawValue)" }
            }
            #expect(Set(extras).isSubset(of: [.breathMarked, .shockDelivered, .metronomeOn, .metronomeOff]), "\(state.id): \(extras)")
        }
    }

    @Test func leavingCPRAlwaysTakesTheHold() throws {
        let bundle = try shippedBundle()
        let kinds = Dictionary(uniqueKeysWithValues: bundle.definition.states.map { ($0.id, $0.kind) })
        for state in bundle.definition.states {
            let controls = try fixture(in: state.id).coordinator.controls
            for control in controls {
                guard let transition = state.transition(on: "human.\(control.action.rawValue)") else { continue }
                let leavesCPR = state.kind == .cpr && kinds[transition.to] != .cpr
                #expect((control.role == .stopsCPR) == leavesCPR, "\(state.id): \(control.action)")
            }
        }
    }

    @Test func startCPRIsOnScreenUntilCompressionsExceptWhereTheEngineWouldIgnoreIt() throws {
        let bundle = try shippedBundle()
        for state in bundle.definition.states {
            let controls = try fixture(in: state.id).coordinator.controls
            let offered = controls.contains { $0.action == .startCpr }
            #expect(offered == (state.transition(on: "human.start_cpr") != nil), "\(state.id)")
            if state.kind == .cpr { #expect(!offered, "\(state.id)") }
        }
    }

    @Test func answersOnlyOnQuestionsAndNotAnAdultOnlyOnIntake() throws {
        for state in try shippedBundle().definition.states {
            let actions = Set(try fixture(in: state.id).coordinator.controls.map(\.action))
            if !actions.isDisjoint(with: [.yes, .no, .unsure]) {
                #expect(state.question != nil, "\(state.id)")
            }
            if actions.contains(.notAdult) { #expect(state.kind == .intake, "\(state.id)") }
        }
    }

    @Test func breathMarksCountOnlyInWatchBreathing() throws {
        let watching = try fixture(in: "watch_breathing")
        #expect(watching.coordinator.controls.contains { $0.action == .breathMarked })
        watching.coordinator.perform(.breathMarked)
        watching.coordinator.perform(.breathMarked)
        #expect(watching.coordinator.state.breathsMarked == 2)
        watching.run(seconds: 10.2)
        #expect(watching.coordinator.state.stateID == "watch_reask", "Two breaths lead to the re-ask, not out of the flow")

        #expect(try !fixture(in: "compressions").coordinator.controls.contains { $0.action == .breathMarked })
    }

    @Test func shockMarkOnlyWhereTheEngineAcceptsIt() throws {
        for state in try shippedBundle().definition.states {
            let driven = try fixture(in: state.id)
            let offered = driven.coordinator.controls.contains { $0.action == .shockDelivered }
            driven.coordinator.perform(.shockDelivered)
            let accepted = driven.coordinator.log.entries.contains { $0.kind == .shockMarked }
            #expect(offered == accepted, "\(state.id)")
        }
    }

    @Test func theMetronomeToggleIsOnlyWhereTheBundleAllowsIt() throws {
        for state in try shippedBundle().definition.states {
            let controls = try fixture(in: state.id).coordinator.controls
            let offered = controls.contains { $0.action == .metronomeOn || $0.action == .metronomeOff }
            #expect(offered == state.metronomeToggleable, "\(state.id)")
        }

        let driven = try fixture(in: "compressions_aed")
        #expect(driven.coordinator.controls.contains { $0.action == .metronomeOn })
        driven.coordinator.perform(.metronomeOn)
        #expect(driven.coordinator.state.metronomeOn)
        #expect(driven.audio.metronome.last == true)
        #expect(driven.coordinator.controls.contains { $0.action == .metronomeOff })

        let other = try fixture(in: "aed_analyze")
        other.coordinator.perform(.metronomeOn)
        #expect(!other.coordinator.state.metronomeOn, "Nothing may start the beat during analysis")
    }

    /// The plan's adult gate catches all four, so the button has to name all four.
    @Test func theAdultGateNamesEveryoneItCatches() throws {
        #expect(RescueControls.title(for: .notAdult) == "Child, infant, drowning, or pregnant")
        for id in ["intake_responsive", "intake_breathing"] {
            let driven = try fixture(in: id)
            let control = try #require(driven.coordinator.controls.first { $0.action == .notAdult }, "\(id)")
            #expect(control.title == "Child, infant, drowning, or pregnant")
            #expect(control.role == .holdStep, "It leaves the adult path with no timeout, so a brush mustn't do it")
            driven.coordinator.perform(.notAdult)
            #expect(driven.coordinator.state.stateID == "special_patient")
        }
    }

    /// The watch intro tells people to tap this, by name.
    @Test func thePhraseNamesTheRealBreathButton() throws {
        let intro = try #require(try shippedBundle().text(forPhrase: "watch_intro"))
        #expect(intro.contains(RescueControls.title(for: .breathMarked)))
        let recheck = try #require(try shippedBundle().text(forPhrase: "responsive_recheck"))
        #expect(recheck.contains(RescueControls.title(for: .patientUnresponsive)))
        let special = try #require(try shippedBundle().text(forPhrase: "special_recheck"))
        #expect(special.contains(RescueControls.title(for: .back)))
    }

    @Test func everyControlHasALabel() throws {
        for action in HumanAction.allCases {
            #expect(!RescueControls.title(for: action).isEmpty)
        }
    }
}

@MainActor
@Suite struct OperatorForceTests {
    @Test func everyStateIsReachableFromEveryState() throws {
        let bundle = try shippedBundle()
        let engine = ProtocolEngine(bundle: bundle)
        for from in bundle.definition.states {
            for to in bundle.definition.states where to.id != from.id {
                #expect(OperatorForce.path(engine: engine, from: from.id, to: to.id) != nil, "\(from.id) to \(to.id)")
            }
        }
    }

    @Test func forcingPlaysOnlyTheDestinationAndInventsNoAnswers() throws {
        let fixture = try Fixture()
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        fixture.audio.clearCalls()

        coordinator.force(stateID: "aed_analyze")

        #expect(coordinator.state.stateID == "aed_analyze")
        #expect(fixture.audio.played == ["aed_authority"])
        #expect(fixture.logDetails(.answer).isEmpty)
        #expect(fixture.logDetails(.stateEntered).contains("operator_forced:aed_analyze"))
        #expect(coordinator.operatorUsed)
        #expect(fixture.audio.metronome.isEmpty, "Off to off, so nothing should click on the way")
    }

    @Test func forcingAppliesTheNetMetronomeChange() throws {
        let fixture = try Fixture()
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        // The last step here stays on, so it emits nothing by itself.
        coordinator.force(stateID: "resource_scan")
        #expect(fixture.audio.metronome == [true])
        coordinator.force(stateID: "handoff")
        #expect(fixture.audio.metronome == [true, false])
    }

    @Test func forcingToATimeoutOnlyStateWorks() throws {
        let fixture = try Fixture()
        fixture.coordinator.beginRescue()
        fixture.coordinator.force(stateID: "watch_reask")
        #expect(fixture.coordinator.state.stateID == "watch_reask")
        #expect(fixture.audio.played.last == "ask_still_breathing")
    }

    /// Stage control has to work after the pads too, or a button on the panel would silently do
    /// nothing. It's still marked OPERATOR USED, and the pads are not forgotten.
    @Test func forcingStillLandsWhereItWasSentOncePadsAreOn() throws {
        let fixture = try Fixture()
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.force(stateID: "aed_analyze")
        #expect(coordinator.state.padsOn)

        coordinator.force(stateID: "compressions")
        #expect(coordinator.state.stateID == "compressions")
        #expect(coordinator.state.padsOn)

        coordinator.force(stateID: "position_patient")
        #expect(coordinator.state.stateID == "position_patient")
        #expect(coordinator.state.padsOn)

        // With the stage over, real taps follow the real rule.
        coordinator.perform(.startCpr)
        #expect(coordinator.state.stateID == "compressions_aed")
        #expect(!coordinator.state.metronomeOn)
    }

    @Test func forcingThroughAnalysisSetsThePads() throws {
        let fixture = try Fixture()
        fixture.coordinator.beginRescue()
        fixture.coordinator.force(stateID: "compressions_aed")
        #expect(fixture.coordinator.state.padsOn)
    }

    @Test func forcingDropsWhatWasQueued() throws {
        let fixture = try Fixture()
        fixture.coordinator.beginRescue()
        fixture.audio.clearCalls()
        fixture.coordinator.force(stateID: "place_hands")
        let drop = try #require(fixture.audio.calls.firstIndex(of: .dropQueued([])))
        let hands = try #require(fixture.audio.calls.firstIndex(of: .play("hands_center")))
        #expect(drop < hands)
    }

    /// The breath count is the arrest path's one clock, and a forced state starts it from now.
    @Test func aForcedStateStillRunsItsOwnTimeoutFromNow() throws {
        let fixture = try Fixture()
        fixture.coordinator.beginRescue()
        fixture.run(seconds: 20)
        fixture.coordinator.force(stateID: "watch_breathing")
        fixture.run(seconds: 9.6)
        #expect(fixture.coordinator.state.stateID == "watch_breathing")
        fixture.run(seconds: 0.6)
        #expect(fixture.coordinator.state.stateID == "position_patient")
    }

    private static let flowModule = Data("""
    {
      "version": "fixture.v1",
      "status": "DRAFT",
      "flow": {"id": "possible_demo", "title": "Possible demo", "rule": "A demo.", "sources": ["Fixture"]},
      "states": [
        {"id": "triage", "kind": "triage", "urgency": 0, "after_pads": "responsive_patient", "entry_phrases": [], "metronome": "off",
         "frame_uplink": false, "allowed_say": [], "transitions": [{"on": "human.triage_chest", "to": "first"}], "citation": "Fixture"},
        {"id": "first", "kind": "flow", "urgency": 2, "flow": "possible_demo", "entry_phrases": [], "metronome": "off",
         "frame_uplink": false, "allowed_say": [], "transitions": [{"on": "human.done", "to": "second"}], "citation": "Fixture"},
        {"id": "second", "kind": "flow", "urgency": 2, "flow": "possible_demo", "entry_phrases": [], "metronome": "off",
         "frame_uplink": false, "allowed_say": [], "transitions": [], "citation": "Fixture"}
      ],
      "replaced_edges": [{"state": "intake_responsive", "edge": {"on": "human.yes", "to": "triage"}}]
    }
    """.utf8)

    private func flowEngine() throws -> ProtocolEngine {
        let merged = try shippedBundle().merging(modules: [ModuleSource(id: "fixture", data: Self.flowModule)], pack: nil)
        #expect(merged.moduleFailures.map(\.id) == [KnowledgePack.id], "\(merged.moduleFailures)")
        return ProtocolEngine(bundle: merged)
    }

    private func flowEntries(_ result: ReduceResult?) -> [LogEntry.Draft] {
        result?.log.filter { $0.kind == .flowEntered } ?? []
    }

    /// The why panel and the card read this from the log, so a walk that drops it or says a person
    /// chose it would be wrong on stage.
    @Test func aForcedWalkRecordsTheFlowItEndsIn() throws {
        let engine = try flowEngine()
        let start = engine.start(at: 0).state
        let expected = [LogEntry.Draft(kind: .flowEntered, source: .system, detail: "possible_demo")]

        let first = try #require(OperatorForce.walk(engine: engine, from: start, to: "first", at: 1))
        #expect(flowEntries(first) == expected, "the step that crossed in was a bystander tap nobody made")
        #expect(flowEntries(OperatorForce.walk(engine: engine, from: start, to: "second", at: 1)) == expected, "the crossing was an earlier step")
    }

    @Test func aForcedWalkInsideOrOutOfAFlowRecordsNone() throws {
        let engine = try flowEngine()
        let start = engine.start(at: 0).state
        let first = try #require(OperatorForce.walk(engine: engine, from: start, to: "first", at: 1)).state

        #expect(flowEntries(OperatorForce.walk(engine: engine, from: first, to: "second", at: 2)).isEmpty)
        #expect(flowEntries(OperatorForce.walk(engine: engine, from: first, to: "triage", at: 2)).isEmpty)
        #expect(flowEntries(OperatorForce.walk(engine: engine, from: start, to: "compressions", at: 2)).isEmpty)
    }

    /// Every later tap in the flow would take a patient who needed CPR on to aspirin and free AI.
    /// Restart rescue is still there for the stage.
    @Test func forcingCantPutAPatientWhoNeededCPRInAnAwakeState() throws {
        let engine = try flowEngine()
        let cpr = try #require(OperatorForce.walk(engine: engine, from: engine.start(at: 0).state, to: "compressions", at: 1)).state
        #expect(cpr.cprStarted)

        #expect(OperatorForce.walk(engine: engine, from: cpr, to: "first", at: 2) == nil)
        #expect(OperatorForce.walk(engine: engine, from: cpr, to: "triage", at: 2) == nil)
    }
}

@Suite struct ProtocolLoaderTests {
    private func shipped() throws -> (protocol: Data, phrases: Data) {
        let protocolURL = try #require(Bundle.main.url(forResource: "adult_arrest.v1", withExtension: "json", subdirectory: "clinical"))
        let phrasesURL = try #require(Bundle.main.url(forResource: "phrases.v1", withExtension: "json", subdirectory: "clinical"))
        return (try Data(contentsOf: protocolURL), try Data(contentsOf: phrasesURL))
    }

    private func mutated(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&json)
        return try JSONSerialization.data(withJSONObject: json)
    }

    @Test func theShippedFilesLoad() throws {
        let data = try shipped()
        #expect(ProtocolLoader.parse(protocolData: data.protocol, phrasesData: data.phrases) != nil)
    }

    @Test func theToolContractShips() throws {
        #expect(try toolContract().isEmpty == false)
    }

    @Test func garbageIsRefusedRatherThanCrashing() throws {
        let data = try shipped()
        #expect(ProtocolLoader.parse(protocolData: Data("not json".utf8), phrasesData: data.phrases) == nil)
        #expect(ProtocolLoader.parse(protocolData: data.protocol, phrasesData: Data("{}".utf8)) == nil)
    }

    @Test func aDuplicateStateIsRefusedSinceTheEngineWouldTrapOnIt() throws {
        let data = try shipped()
        let bad = try mutated(data.protocol) { json in
            var states = json["states"] as? [[String: Any]] ?? []
            states.append(states[0])
            json["states"] = states
        }
        #expect(ProtocolLoader.parse(protocolData: bad, phrasesData: data.phrases) == nil)
    }

    @Test func aDanglingTransitionIsRefused() throws {
        let data = try shipped()
        let bad = try mutated(data.protocol) { json in
            var states = json["states"] as? [[String: Any]] ?? []
            var transitions = states[0]["transitions"] as? [[String: Any]] ?? []
            transitions[0]["to"] = "nowhere"
            states[0]["transitions"] = transitions
            json["states"] = states
        }
        #expect(ProtocolLoader.parse(protocolData: bad, phrasesData: data.phrases) == nil)
    }

    @Test func aMissingPhraseIsRefused() throws {
        let data = try shipped()
        let bad = try mutated(data.phrases) { json in
            var phrases = json["phrases"] as? [[String: Any]] ?? []
            phrases.removeAll { $0["id"] as? String == "start_compressions" }
            json["phrases"] = phrases
        }
        #expect(ProtocolLoader.parse(protocolData: data.protocol, phrasesData: bad) == nil)
    }

    @MainActor @Test func hostedTestsDoNotStartTheRealApp() {
        if case .underTest = AppBoot.make() { return }
        Issue.record("The test host would have started real audio and AR")
    }

    @MainActor @Test func anEmptyKeyMeansNoKey() {
        // Never read from this build's plist, which holds a real key on a configured machine.
        for empty in [nil, "", "   ", "$(GEMINI_API_KEY)"] {
            #expect(AppBoot.apiKey(plistValue: empty) == nil)
        }
        #expect(AppBoot.apiKey(plistValue: "not-a-real-key") != nil)
    }

    /// An unset voice leaves Live on its default rather than sending a name it doesn't know.
    @MainActor @Test func anEmptyVoiceMeansNoVoice() {
        for empty in [nil, "", "   ", "$(GEMINI_VOICE)"] {
            #expect(AppBoot.voiceName(plistValue: empty) == nil)
        }
        #expect(AppBoot.voiceName(plistValue: " Kore\n") == "Kore")
    }

    /// The clips and the AI share one voice, which this build's settings name.
    @MainActor @Test func theBuildNamesTheVoiceTheClipsUse() {
        #expect(AppBoot.voiceName(in: .main) == "Kore")
    }
}

@Suite struct ModuleLoaderTests {
    private static let triage = Data("""
    {
      "version": "triage.v1",
      "status": "DRAFT",
      "states": [{
        "id": "triage", "kind": "triage", "urgency": 0, "after_pads": "responsive_patient", "entry_phrases": ["fixture_ask"], "metronome": "off",
        "frame_uplink": false, "allowed_say": [], "transitions": [], "citation": "Fixture"
      }],
      "phrases": [{"id": "fixture_ask", "text": "What is going on?", "citation": "Fixture"}],
      "replaced_edges": [{"state": "intake_responsive", "edge": {"on": "human.yes", "to": "triage"}}],
      "open_states": ["triage"]
    }
    """.utf8)

    /// Laid out like the app, so a module can sit where the loader really looks.
    private func appLayout(modules: [String: Data] = [:], without missing: String? = nil, corrupting corrupt: String? = nil) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).bundle")
        let clinical = root.appendingPathComponent("clinical")
        let folder = clinical.appendingPathComponent("modules")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["adult_arrest.v1", "phrases.v1", KnowledgePack.id] where name != missing {
            let shipped = try #require(Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "clinical"), "\(name)")
            let copy = clinical.appendingPathComponent("\(name).json")
            try FileManager.default.copyItem(at: shipped, to: copy)
            if name == corrupt { try Data("not json".utf8).write(to: copy) }
        }
        for (name, data) in modules {
            try data.write(to: folder.appendingPathComponent("\(name).json"))
        }
        return try #require(Bundle(url: root))
    }

    private func yesTarget(_ bundle: ProtocolBundle) -> String? {
        bundle.definition.states.first { $0.id == "intake_responsive" }?.transition(on: "human.yes")?.to
    }

    /// The modules arrive over later steps. The repo says which have arrived, so a file that didn't
    /// reach the app fails here instead of quietly booting today's behaviour.
    @Test func theAppBundleLoadsWhatItShips() throws {
        let merged = try #require(ProtocolLoader.loadMerged(from: .main))
        #expect(merged.knowledgePack != nil, "the pack did not ship in the app bundle")

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "clinical/modules").path)) ?? []
        let present = Set(files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(".json".count)) })
        #expect(present.isSubset(of: ScenarioModule.manifest), "\(present) would never load")

        #expect(merged.moduleFailures.allSatisfy { ScenarioModule.manifest.contains($0.id) }, "\(merged.moduleFailures)")
        for id in ScenarioModule.manifest {
            let failure = merged.moduleFailures.first { $0.id == id }
            if present.contains(id) {
                #expect(failure == nil, "\(id): \(failure?.reason ?? "")")
            } else {
                #expect(failure?.reason == "missing", "\(id): \(failure?.reason ?? "loaded")")
            }
        }
    }

    /// An awake state offers the adult gate like intake does, and a brush mustn't do it there either.
    @Test func anAwakeStateKeepsTheAdultGatesHold() throws {
        let bundle = try appLayout(modules: ["triage.v1": Self.triage])
        let merged = try #require(ProtocolLoader.loadMerged(from: bundle))
        let engine = ProtocolEngine(bundle: merged)
        let triage = try #require(engine.definition(of: "triage"))
        let controls = RescueControls.derive(definition: triage, engine: engine, metronomeOn: false)
        #expect(controls.first { $0.action == .notAdult }?.role == .holdStep)
    }

    @Test func missingModulesLeaveTheAppAsItWas() throws {
        let bundle = try appLayout()
        let core = try #require(ProtocolLoader.load(from: bundle))
        let merged = try #require(ProtocolLoader.loadMerged(from: bundle))

        #expect(merged.moduleFailures.map(\.id) == ScenarioModule.manifest)
        #expect(merged.moduleFailures.allSatisfy { $0.reason == "missing" })
        #expect(merged.definition == core.definition)
        #expect(merged.phrases == core.phrases)
        #expect(merged.knowledgePack != nil)
    }

    @Test func aModuleIsFoundInItsSubdirectory() throws {
        let bundle = try appLayout(modules: ["triage.v1": Self.triage])
        let merged = try #require(ProtocolLoader.loadMerged(from: bundle))

        #expect(merged.moduleFailures.map(\.id) == ["possible_heart_attack.v1", "possible_broken_bone.v1"])
        #expect(yesTarget(merged) == "triage")
        #expect(merged.definition.speechGate.openStates.contains("triage"))
    }

    /// The arrest tests rely on this staying core only, whatever modules ship.
    @Test func theCoreLoadIgnoresModules() throws {
        let bundle = try appLayout(modules: ["triage.v1": Self.triage])
        let core = try #require(ProtocolLoader.load(from: bundle))
        #expect(yesTarget(core) == "responsive_patient")
        #expect(core.moduleFailures.isEmpty)
    }

    @Test func aCorruptModuleIsNamedAndCoreRuns() throws {
        let bundle = try appLayout(modules: ["triage.v1": Data("not json".utf8)])
        let merged = try #require(ProtocolLoader.loadMerged(from: bundle))

        #expect(merged.moduleFailures.first?.id == "triage.v1")
        #expect(merged.moduleFailures.first?.reason == "does not decode")
        #expect(yesTarget(merged) == "responsive_patient")
        var result = ProtocolEngine(bundle: merged).start(at: 0)
        result = ProtocolEngine(bundle: merged).reduce(result.state, .human(.no), at: 1)
        #expect(result.state.stateID == "intake_breathing")
    }

    @Test func aMissingPackClosesVoiceAndKeepsTheModule() throws {
        let bundle = try appLayout(modules: ["triage.v1": Self.triage], without: KnowledgePack.id)
        let merged = try #require(ProtocolLoader.loadMerged(from: bundle))

        #expect(merged.knowledgePack == nil)
        #expect(merged.moduleFailures.contains { $0.id == KnowledgePack.id && $0.reason == "missing" })
        #expect(yesTarget(merged) == "triage")
        #expect(!merged.definition.speechGate.openStates.contains("triage"))
    }

    @Test(arguments: ["adult_arrest.v1", "phrases.v1"])
    func aBadCoreStillStopsTheApp(file: String) throws {
        let corrupt = try appLayout(modules: ["triage.v1": Self.triage], corrupting: file)
        #expect(ProtocolLoader.loadMerged(from: corrupt) == nil)
        let missing = try appLayout(modules: ["triage.v1": Self.triage], without: file)
        #expect(ProtocolLoader.loadMerged(from: missing) == nil)
    }
}
