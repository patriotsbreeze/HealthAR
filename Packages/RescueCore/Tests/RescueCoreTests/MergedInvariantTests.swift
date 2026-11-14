import Foundation
import Testing
@testable import RescueCore

private let everyAwakeState = [
    "triage", "general_talk", "choking_talk",
    "chest_call", "chest_aspirin_check", "chest_aspirin", "chest_wait", "chest_scan",
    "limb_start", "limb_flags", "limb_splint", "limb_wait", "limb_danger",
]

/// What has to stay true of the merged graph. Numbers match the invariants in SAFETY.md. The arrest
/// suite stays on the core bundle in `InvariantTests`, and these never replace it.
@Suite struct MergedInvariantTests {
    private func engine() throws -> ProtocolEngine { ProtocolEngine(bundle: try loadMergedBundle()) }

    /// Only a tap may land on these.
    private let humanOnly: Set<String> = ["assess", "triage", "chest_aspirin"]

    /// As if the rest of the rescue had got it there.
    private func session(_ engine: ProtocolEngine, in id: String) throws -> Session {
        var session = Session(engine: engine)
        let definition = try #require(engine.definition(of: id))
        session.state.stateID = id
        session.state.enteredAt = session.now
        session.state.metronomeOn = definition.metronome == .on
        session.state.cprStarted = definition.kind == .cpr
        session.state.padsOn = id == "aed_analyze" || id == "compressions_aed"
        session.state.awakeSinceVersion = definition.kind.isAwake ? session.state.version : nil
        return session
    }

    private func walk(to id: String, _ session: inout Session) {
        session.human(.yes)
        if id == "triage" { return }
        if id == "general_talk" { return session.human(.triageOther) }
        if id == "choking_talk" {
            session.human(.triageOther)
            return session.human(.triageChoking)
        }
        if id.hasPrefix("limb_") {
            session.human(.triageLimb)
            if id == "limb_start" { return }
            session.human(.done)
            if id == "limb_flags" { return }
            if id == "limb_danger" { return session.human(.yes) }
            session.human(.no)
            if id == "limb_splint" { return }
            return session.human(.done)
        }
        session.human(.triageChest)
        if id == "chest_call" { return }
        session.human(.done)
        if id == "chest_aspirin_check" { return }
        if id == "chest_aspirin" { return session.human(.no) }
        session.human(.yes)
        if id == "chest_wait" { return }
        session.human(.scan)
    }

    // MARK: - What's merged

    @Test func theModulesThisSuiteCoversLoaded() throws {
        let bundle = try loadMergedBundle()
        #expect(bundle.moduleFailures.isEmpty, "\(bundle.moduleFailures)")
        #expect(bundle.flows.map(\.id) == ["possible_heart_attack", "possible_broken_bone"])
        let awake = bundle.definition.states.filter(\.kind.isAwake).map(\.id)
        // Assess is only ever where a rescue opens, so no walk from core reaches it. `AssessTests` covers it.
        #expect(Set(awake) == Set(everyAwakeState + [ScenarioModule.assessState]), "a new state needs a walk below")
    }

    /// The walk the rest of this suite relies on is the real one.
    @Test(arguments: everyAwakeState)
    func everyAwakeStateIsReachedByTaps(id: String) throws {
        var session = Session(engine: try engine())
        walk(to: id, &session)
        #expect(session.state.stateID == id)
    }

    // MARK: - 12. Unresponsive always follows CPR

    @Test func everyAwakeStateHasEveryInjectedEdge() throws {
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
        let collapses: Set = ["human.start_cpr", "human.patient_unresponsive", "model.unresponsive", "model.not_breathing", "model.abnormal_breathing"]
        for state in try loadMergedBundle().definition.states where state.kind.isAwake {
            for (key, target) in targets {
                let edges = state.transitions.filter { $0.on == key }
                // Assess holds the AI's collapse reports as suggestions, so they carry no edge there.
                if state.id == ScenarioModule.assessState, ScenarioModule.assessHeldReports.contains(key) {
                    #expect(edges.isEmpty, "assess \(key) must only suggest")
                    continue
                }
                #expect(edges.count == 1, "\(state.id) \(key)")
                #expect(edges.first?.to == target, "\(state.id) \(key)")
                #expect(edges.first?.cutsPhrases == collapses.contains(key), "\(state.id) \(key)")
                #expect(edges.first?.minConfidence == nil, "\(state.id) \(key) must not wait for a sure report")
            }
        }
    }

    /// With no further input a collapse gets as far as the call, which waits for a tap, and one Start
    /// CPR tap from there reaches the beat.
    /// A tap or something the rescuer said takes an awake patient to the breathing question or CPR,
    /// never lower, and from there it waits on them. What the AI only saw moves nothing.
    @Test func everyCollapseReachesTheBreathingQuestionAndWaitsThere() throws {
        let engine = try engine()
        let triggers: [(String, (inout Session) -> Void)] = [
            ("tap, start CPR", { $0.human(.startCpr) }),
            ("tap, not responding", { $0.human(.patientUnresponsive) }),
            ("report, unresponsive", { $0.model(.reportFinding(.unresponsive, source: .heard, confidence: .low)) }),
            ("report, not breathing", { $0.model(.reportFinding(.notBreathing, source: .heard, confidence: .low)) }),
            ("report, abnormal breathing", { $0.model(.reportFinding(.abnormalBreathing, source: .heard, confidence: .low)) }),
        ]
        for state in engine.bundle.definition.states where state.kind.isAwake {
            for (name, trigger) in triggers {
                var session = try session(engine, in: state.id)
                trigger(&session)
                let reached = session.state.stateID
                if state.id == ScenarioModule.assessState, name.hasPrefix("report") {
                    #expect(reached == state.id, "assess, \(name): a report only suggests")
                    continue
                }
                #expect(["intake_breathing", "compressions"].contains(reached), "\(state.id), \(name)")
                #expect(session.effects.contains(.cutPhrases), "\(state.id), \(name)")
                let urgency = try #require(engine.definition(of: reached)).urgency
                #expect(urgency >= state.urgency, "\(state.id), \(name)")
                for _ in 0..<40 { session.advance(1) }
                #expect(session.state.stateID == reached, "\(state.id), \(name) moved on by itself")
                session.human(.startCpr)
                #expect(session.state.stateID == "compressions", "\(state.id), \(name)")
                #expect(session.state.metronomeOn, "\(state.id), \(name)")
            }

            var seen = try session(engine, in: state.id)
            seen.model(.reportFinding(.abnormalBreathing, source: .seen, confidence: .high))
            #expect(seen.state.stateID == state.id, "\(state.id): a camera report moved the step")
        }
    }

    /// Reports alone never reach compressions from an awake state: only a tap or the question's own
    /// timeout gets past it. Hostile, so every state gets every pair of reports, each one quoting the
    /// current version.
    @Test func noPairOfReportsGetsPastTheBreathingQuestion() throws {
        let engine = try engine()
        let collapses = [Finding.unresponsive, .notBreathing, .abnormalBreathing]
        for state in engine.bundle.definition.states where state.kind.isAwake {
            for first in collapses {
                for second in collapses {
                    var session = try session(engine, in: state.id)
                    if state.id == ScenarioModule.assessState {
                        session.modelFinding(first)
                        session.now += 0.5
                        session.modelFinding(second)
                        #expect(session.state.stateID == state.id, "assess \(first) \(second): reports only suggest")
                        continue
                    }
                    session.modelFinding(first)
                    #expect(session.state.stateID == "intake_breathing", "\(state.id) \(first)")
                    session.now += 0.5
                    session.modelFinding(second)
                    #expect(session.state.stateID == "intake_breathing", "\(state.id) \(first) \(second)")
                }
            }
        }
    }

    /// Their timers end in the safer branch, never in compressions, whoever was or wasn't there.
    @Test func noAwakeStateTimesOutIntoCPR() throws {
        let engine = try engine()
        // Nobody has said the patient on assess is awake, so its silence goes to the arrest questions,
        // which `AssessTests` holds to never reaching CPR without a tap.
        for state in engine.bundle.definition.states where state.kind.isAwake && state.id != ScenarioModule.assessState {
            var session = try session(engine, in: state.id)
            for _ in 0..<300 {
                session.advance(1)
                let current = try #require(engine.definition(of: session.state.stateID))
                #expect(current.kind.isAwake, "\(state.id) timed out to \(current.id)")
                #expect(!session.state.metronomeOn, "\(state.id)")
            }
        }
    }

    // MARK: - 13. The AI chooses among awake flows, after a tap, and only upward

    @Test func noModelEdgeOrTimeoutCanLandOnAHumanOnlyState() throws {
        let definition = try loadMergedBundle().definition
        let states = Dictionary(uniqueKeysWithValues: definition.states.map { ($0.id, $0) })
        func landings(_ id: String) -> [String] { [id] + [states[id]?.afterPads].compactMap { $0 } }

        for state in definition.states {
            for edge in state.transitions where edge.on.hasPrefix("model.") {
                #expect(humanOnly.isDisjoint(with: landings(edge.to)), "\(state.id) \(edge.on)")
            }
            for target in [state.timeout?.to, state.timeout?.ifBreathsAtLeast?.to].compactMap({ $0 }) {
                #expect(humanOnly.isDisjoint(with: landings(target)), "\(state.id) times out to \(target)")
            }
        }
    }

    /// The list above has to keep up, so a new state that advises a dose fails here until it's on it.
    @Test func everyStateThatAdvisesAspirinIsHumanOnly() throws {
        let definition = try loadMergedBundle().definition
        let advising = Set(definition.states.filter { $0.logOnEnter == .aspirinAdvised }.map(\.id))
        #expect(advising == ["chest_aspirin"])
        #expect(advising.isSubset(of: humanOnly))
    }

    /// Every report into the heart attack flow lands where the call comes first.
    @Test func aModelEdgeIntoTheChestFlowOnlyReachesItsFirstStep() throws {
        let definition = try loadMergedBundle().definition
        let chest = Set(definition.states.filter { $0.flow == "possible_heart_attack" }.map(\.id))
        var entries = 0
        for state in definition.states where !chest.contains(state.id) {
            for edge in state.transitions where edge.on.hasPrefix("model.") && chest.contains(edge.to) {
                #expect(edge.to == "chest_call", "\(state.id) \(edge.on)")
                #expect(edge.minConfidence == .medium, "\(state.id) \(edge.on)")
                entries += 1
            }
        }
        #expect(entries == 6)
    }

    @Test func theArrestPathTakesNoRoutingReportAtAll() throws {
        let definition = try loadMergedBundle().definition
        let routing = Set(Finding.allCases.filter { !Finding.arrestCases.contains($0) }.map { "model.\($0.rawValue)" })
        for state in definition.states where state.kind.isArrestPath {
            #expect(routing.isDisjoint(with: state.transitions.map(\.on)), "\(state.id)")
        }
    }

    /// Hostile on purpose. Every state gets the same share, and the seed is fixed so a failure reproduces.
    @Test func tenThousandFuzzedSessionsFromEveryStateBreakNoRule() throws {
        let engine = try engine()
        let definition = engine.bundle.definition
        let states = Dictionary(uniqueKeysWithValues: definition.states.map { ($0.id, $0) })
        let phraseIDs = engine.bundle.phrases.phrases.map(\.id) + ["made_up"]
        var rng = SplitMix64(state: 20_261_106)
        var moved = (model: 0, timer: 0, crossings: 0)

        func modelAction() -> ModelProposal.Action {
            switch Int.random(in: 0..<8, using: &rng) {
            case 0..<5:
                .reportFinding(
                    Finding.allCases.randomElement(using: &rng)!,
                    source: ObservationSource.allCases.randomElement(using: &rng)!,
                    confidence: Confidence.allCases.randomElement(using: &rng)!
                )
            case 5: .say(phraseID: phraseIDs.randomElement(using: &rng)!)
            case 6: .reportResources([Resource.allCases.randomElement(using: &rng)!])
            default: .locateObject(.aed)
            }
        }

        func proposal(_ state: RescueState, at now: TimeInterval) -> ModelProposal {
            let age = Int.random(in: 0..<8, using: &rng)
            let version = switch age {
            case 0, 1: state.version - Int.random(in: 1...3, using: &rng)
            case 2: state.version + 1
            default: state.version
            }
            return ModelProposal(action: modelAction(), stateVersion: version, issuedAt: age == 3 ? now - 6 : now)
        }

        for index in 0..<10_000 {
            var session = try session(engine, in: definition.states[index % definition.states.count].id)
            // Flags a person couldn't have set before reaching an awake state stay off those.
            if !states[session.state.stateID]!.kind.isAwake {
                session.state.cprStarted = session.state.cprStarted || Int.random(in: 0..<6, using: &rng) == 0
                session.state.padsOn = session.state.padsOn || Int.random(in: 0..<6, using: &rng) == 0
            }

            for _ in 0..<20 {
                let before = session.state
                session.now += Double.random(in: 0...2, using: &rng)

                let event: RescueEvent
                switch Int.random(in: 0..<21, using: &rng) {
                case 0..<6: event = .human(HumanAction.allCases.randomElement(using: &rng)!)
                case 6..<14: event = .model(proposal(before, at: session.now))
                case 14..<18:
                    session.now += Double.random(in: 0...35, using: &rng)
                    event = .tick
                case 18: event = .sentinelFlag(SentinelFlag(category: SentinelFlag.Category.awakeCases.randomElement(using: &rng)!, excerpt: "x"))
                case 19: event = .modelTurn(active: Bool.random(using: &rng))
                default: event = .keyword(AudioKeyword.allCases.randomElement(using: &rng)!)
                }
                session.send(event)

                let from = states[before.stateID]!
                let to = states[session.state.stateID]!
                let where_ = "\(from.id) to \(to.id) on \(event)"
                if case .human = event {
                    if from.kind.isArrestPath, to.kind.isAwake {
                        moved.crossings += 1
                        if from.id != "intake_responsive" || event != .human(.yes) { Issue.record("crossed by tap: \(where_)") }
                    }
                } else {
                    if to.urgency < from.urgency { Issue.record("lowered urgency: \(where_)") }
                    if from.kind.isArrestPath, !to.kind.isArrestPath { Issue.record("left the arrest path: \(where_)") }
                    if from.id != to.id {
                        if humanOnly.contains(to.id) { Issue.record("reached a human-only state: \(where_)") }
                        if case .tick = event { moved.timer += 1 } else { moved.model += 1 }
                    }
                }
                if to.kind.isAwake, session.state.padsOn || session.state.cprStarted {
                    Issue.record("awake after pads or CPR: \(where_)")
                }
                if to.metronome == .off, !to.metronomeToggleable, session.state.metronomeOn {
                    Issue.record("beat on in \(to.id)")
                }
            }
        }
        // So a change that stopped anything moving couldn't pass this.
        #expect(moved.model > 0)
        #expect(moved.timer > 0)
        #expect(moved.crossings > 0)
    }

    // MARK: - 14. A bad scenario file can't affect arrest

    private func shippedSources() throws -> [ModuleSource] {
        let folder = repoRoot().appendingPathComponent("clinical/modules")
        return ScenarioModule.manifest.map { id in
            ModuleSource(id: id, data: try? Data(contentsOf: folder.appendingPathComponent("\(id).json")))
        }
    }

    private func pack() throws -> Data {
        try Data(contentsOf: repoRoot().appendingPathComponent("clinical/\(KnowledgePack.id).json"))
    }

    @Test(arguments: ScenarioModule.manifest)
    func aCorruptModuleLeavesEveryArrestStateAsItShipped(id: String) throws {
        let core = try loadBundle()
        let sources = try shippedSources().map { $0.id == id ? ModuleSource(id: id, data: Data("not json".utf8)) : $0 }
        let merged = core.merging(modules: sources, pack: try pack())
        #expect(merged.moduleFailures.contains { $0.id == id && $0.reason == "does not decode" })

        let moved = "intake_responsive"
        #expect(merged.definition.states.filter { $0.kind.isArrestPath && $0.id != moved } == core.definition.states.filter { $0.kind.isArrestPath && $0.id != moved })
        var session = Session(engine: ProtocolEngine(bundle: merged))
        session.human(.startCpr)
        #expect(session.state.stateID == "compressions")
    }

    /// Without triage there's nothing to hang a flow on, so Yes goes back to the card it always went to.
    @Test func noTriageMeansNoFlowsAndTodaysYes() throws {
        let core = try loadBundle()
        let sources = try shippedSources().map { $0.id == "triage.v1" ? ModuleSource(id: $0.id, data: nil) : $0 }
        let merged = core.merging(modules: sources, pack: try pack())
        #expect(merged.flows.isEmpty)
        #expect(merged.definition == core.definition)
        #expect(merged.phrases == core.phrases)

        var session = Session(engine: ProtocolEngine(bundle: merged))
        session.human(.yes)
        #expect(session.state.stateID == "responsive_patient")
    }

    /// A dropped flow takes its own button and edges with it, so triage doesn't offer a dead end.
    @Test func aDroppedFlowTakesItsButtonWithIt() throws {
        let sources = try shippedSources().map { $0.id == "possible_heart_attack.v1" ? ModuleSource(id: $0.id, data: Data("{}".utf8)) : $0 }
        let merged = try loadBundle().merging(modules: sources, pack: try pack())
        let triage = try #require(merged.definition.states.first { $0.id == "triage" })
        let talk = try #require(merged.definition.states.first { $0.id == "general_talk" })
        #expect(merged.definition.states.first { $0.id == "chest_call" } == nil)
        for key in ["human.triage_chest", "model.chest_pain", "model.other_heart_signs"] {
            #expect(triage.transition(on: key) == nil, "\(key)")
        }
        #expect(talk.transition(on: "model.chest_pain") == nil)
        #expect(triage.transition(on: "human.triage_other") != nil)
    }

    @Test func aDroppedBrokenBoneFlowTakesItsButtonWithIt() throws {
        let sources = try shippedSources().map { $0.id == "possible_broken_bone.v1" ? ModuleSource(id: $0.id, data: Data("{}".utf8)) : $0 }
        let merged = try loadBundle().merging(modules: sources, pack: try pack())
        let triage = try #require(merged.definition.states.first { $0.id == "triage" })
        let talk = try #require(merged.definition.states.first { $0.id == "general_talk" })
        #expect(!merged.definition.states.contains { $0.flow == "possible_broken_bone" })
        #expect(triage.transition(on: "human.triage_limb") == nil)
        for key in ["model.limb_injury", "model.heavy_bleeding", "model.limb_discolored", "model.neck_back_injury"] {
            #expect(triage.transition(on: key) == nil, "\(key)")
            #expect(talk.transition(on: key) == nil, "\(key)")
        }
        #expect(triage.transition(on: "human.triage_chest") != nil)
        #expect(!merged.definition.speechGate.openStates.contains("limb_wait"))
        #expect(!merged.phrases.phrases.contains { $0.id.hasPrefix("limb_") })
    }

    /// A flow that leaned on another would go down with it, whichever file was the bad one.
    @Test(arguments: [("possible_heart_attack", "possible_broken_bone"), ("possible_broken_bone", "possible_heart_attack")])
    func eachFlowLoadsWhole(without dropped: String, kept: String) throws {
        let whole = try loadMergedBundle()
        let sources = try shippedSources().map { $0.id == "\(dropped).v1" ? ModuleSource(id: $0.id, data: nil) : $0 }
        let merged = try loadBundle().merging(modules: sources, pack: try pack())
        #expect(merged.moduleFailures == [ModuleFailure(id: "\(dropped).v1", reason: "missing")])
        #expect(merged.flows.map(\.id) == [kept])
        #expect(merged.definition.states.filter { $0.flow == kept } == whole.definition.states.filter { $0.flow == kept })
        #expect(!merged.definition.states.contains { $0.flow == dropped })
    }

    @Test func noEdgeJoinsOneFlowToAnother() throws {
        let definition = try loadMergedBundle().definition
        let flows = Dictionary(uniqueKeysWithValues: definition.states.compactMap { state in state.flow.map { (state.id, $0) } })
        for state in definition.states {
            guard let flow = state.flow else { continue }
            let targets = state.transitions.map(\.to) + [state.timeout?.to, state.timeout?.ifBreathsAtLeast?.to, state.afterPads].compactMap { $0 }
            for target in targets {
                if let other = flows[target] { #expect(other == flow, "\(state.id) to \(target)") }
            }
        }
    }

    /// The same events on both bundles, wherever they agree, must do exactly the same. Only the one
    /// moved edge and the one added button may tell them apart.
    @Test func theArrestPathRunsTheSameOnTheMergedBundle() throws {
        let core = ProtocolEngine(bundle: try loadBundle())
        let merged = try engine()
        let starts = core.bundle.definition.states.map(\.id)
        var rng = SplitMix64(state: 77)

        for index in 0..<2_000 {
            var left = try session(core, in: starts[index % starts.count])
            var right = try session(merged, in: starts[index % starts.count])
            for _ in 0..<25 {
                let advance = Double.random(in: 0...12, using: &rng)
                let event: RescueEvent
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: event = .human(HumanAction.allCases.randomElement(using: &rng)!)
                case 1:
                    event = .model(ModelProposal(
                        action: .reportFinding(Finding.allCases.randomElement(using: &rng)!, source: .heard, confidence: .high),
                        stateVersion: left.state.version,
                        issuedAt: left.now
                    ))
                default:
                    left.now += advance
                    right.now += advance
                    event = .tick
                }
                if event == .human(.triageOpen) { continue }
                if event == .human(.yes), left.state.stateID == "intake_responsive" { continue }

                left.send(event)
                right.send(event)
                if left.state != right.state || left.effects != right.effects || left.log != right.log {
                    Issue.record("\(event) in \(left.state.stateID) diverged")
                    return
                }
            }
        }
    }

    /// The question is asked three times over 30 s, then the call step waits, saying its line every
    /// 10 s, and one Start CPR tap reaches the beat.
    @Test func noTouchLaunchStaysOnTheFirstQuestionAndKeepsAsking() throws {
        var session = Session(engine: try engine())
        let started = session.now
        while session.now - started < 60 { session.advance(0.2) }
        #expect(session.state.stateID == "intake_responsive")
        #expect(session.allPhrases.allSatisfy { $0 == "ask_responsive" })
        #expect(session.allPhrases.count >= 6, "asked again every 10 s")
        #expect(!session.state.metronomeOn)

        session.human(.startCpr)
        #expect(session.state.stateID == "compressions")
        #expect(session.state.metronomeOn)
    }

    // MARK: - 15. Never a fact, a dose, or a clinician

    @Test func theOnlyDoseIsTheOneApprovedPhrase() throws {
        let core = Set(try loadBundle().phrases.phrases.map(\.id))
        for phrase in try loadMergedBundle().phrases.phrases where !core.contains(phrase.id) {
            let flags = TranscriptValidator.check(phrase.text, profile: .awake)
            #expect(flags.map(\.category) == (phrase.id == "aspirin_give" ? [.dose] : []), "\(phrase.id): \(flags)")
            let hasNumber = phrase.text.range(of: #"\d"#, options: .regularExpression) != nil
            #expect(hasNumber == ["aspirin_give", "general_intro", "choking_steps", "limb_seek_care", "triage_recheck"].contains(phrase.id), "\(phrase.id)")
        }
    }

    @Test func everyFlowSaysPossibleAndNoPhraseCallsItAFact() throws {
        let bundle = try loadMergedBundle()
        #expect(!bundle.flows.isEmpty)
        for flow in bundle.flows {
            #expect(flow.id.hasPrefix("possible_"), "\(flow.id)")
            #expect(flow.title.hasPrefix("Possible "), "\(flow.title)")
            #expect(!flow.rule.isEmpty)
            #expect(!flow.sources.isEmpty)
        }
        let core = Set(try loadBundle().phrases.phrases.map(\.id))
        for phrase in bundle.phrases.phrases where !core.contains(phrase.id) {
            let text = phrase.text.lowercased()
            for condition in ["heart attack", "broken bone"] where text.contains(condition) {
                #expect(text.contains("possible \(condition)") || text.contains("may be"), "\(phrase.id)")
            }
        }
    }

    @Test func theCorrectionMapCoversEveryAwakeCategory() throws {
        let bundle = try loadMergedBundle()
        let map = bundle.awakeCorrectionPhrases
        #expect(Set(map.keys) == Set(SentinelFlag.Category.awakeCases.map(\.rawValue)))
        #expect(Set(map.values) == ["correct_diagnosis", "correct_identity", "correct_awake"])
        #expect(map["diagnosis"] == "correct_diagnosis")
        #expect(map["identity"] == "correct_identity")
        for id in map.values { #expect(bundle.text(forPhrase: id) != nil, "\(id)") }
    }

    /// Every awake category is answered in its own words, and none falls through to CPR's.
    @Test(arguments: SentinelFlag.Category.awakeCases)
    func everyAwakeCategoryGetsAnAwakeCorrection(category: SentinelFlag.Category) throws {
        var session = Session(engine: try engine())
        walk(to: "triage", &session)
        session.send(.sentinelFlag(SentinelFlag(category: category, excerpt: "x")))
        let expected = switch category {
        case .diagnosis: "correct_diagnosis"
        case .identity: "correct_identity"
        default: "correct_awake"
        }
        #expect(session.phrases == [expected])
    }

    /// What the app boots with for now: the arrest speech table as it shipped, and nothing else changed.
    @Test func closingAwakeVoiceTouchesOnlyTheAwakeStates() throws {
        let merged = try loadMergedBundle()
        var closed = merged.closingAwakeVoice()
        #expect(closed.definition.speechGate == (try loadBundle()).definition.speechGate)
        closed.definition.speechGate = merged.definition.speechGate
        #expect(closed == merged)
    }

    // MARK: - 10, 11. PPG and frames

    @Test func ppgStaysOnTheStaticCard() throws {
        let definition = try loadMergedBundle().definition
        #expect(definition.states.filter(\.allowsPpg).map(\.id) == ["responsive_patient"])
    }

    /// Only the scan asks to see the room, and only local steps run until voice opens.
    @Test func theSpeechAndFrameTablesStayNarrow() throws {
        let core = try loadBundle().definition
        let definition = try loadMergedBundle().definition
        let states = Dictionary(uniqueKeysWithValues: definition.states.map { ($0.id, $0) })

        let opened = Set(definition.speechGate.openStates).subtracting(core.speechGate.openStates)
        #expect(Set(core.speechGate.openStates).isSubset(of: definition.speechGate.openStates))
        #expect(opened.isSuperset(of: ["triage", "general_talk", "chest_wait", "limb_wait", "limb_danger"]))
        #expect(opened.allSatisfy { states[$0]?.kind.isAwake == true }, "\(opened)")
        #expect(opened.isDisjoint(with: ["chest_call", "chest_aspirin_check", "chest_aspirin", "chest_scan", "limb_start", "limb_flags", "limb_splint"]))

        let framed = definition.states.filter { $0.kind.isAwake && $0.frameUplink }.map(\.id)
        #expect(framed == ["assess", "chest_scan"])
        #expect(states["chest_scan"]?.overlay == .aedDevice)
    }

    /// A limb step may send a single frozen frame to the locator to find a towel, and nothing to the
    /// Live session. Never on the arrest path, and never during a call.
    @Test func onlyTheLimbStepsLocateMaterialsAndNoneOfThemStreams() throws {
        let engine = try engine()
        let located = engine.bundle.definition.states.filter(\.locateMaterials).map(\.id)
        #expect(located == ["limb_start", "limb_flags", "limb_splint", "limb_wait", "limb_danger"])
        for definition in engine.bundle.definition.states {
            var state = engine.start(at: 0).state
            state.stateID = definition.id
            let policy = engine.policy(for: state, at: 0)
            #expect(policy.frameLocate == definition.locateMaterials, "\(definition.id)")
            if policy.frameLocate {
                #expect(definition.kind.isAwake, "\(definition.id)")
                #expect(!policy.frameUplink, "\(definition.id) streams to Live")
            }
            state.callActive = true
            #expect(!engine.policy(for: state, at: 0).frameLocate, "\(definition.id) during a call")
        }
    }

    // MARK: - 4. Said before the step moves on

    /// Rendered from the real clips, which are gitignored, so this is off in a checkout without them.
    private static let clips = repoRoot().appendingPathComponent("App/Resources/phrases")
    private static let clipsRendered = FileManager.default.fileExists(atPath: clips.appendingPathComponent("aspirin_check.wav").path)

    private func seconds(_ id: String) throws -> TimeInterval {
        let data = try Data(contentsOf: Self.clips.appendingPathComponent("\(id).wav"))
        var offset = 12
        while offset + 8 <= data.count {
            let tag = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = data[offset + 4..<offset + 8].reversed().reduce(0) { $0 << 8 + Int($1) }
            if tag == "data" { return TimeInterval(size) / 48_000 }
            offset += 8 + size + size % 2
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    private func speech(_ phrases: [String]) throws -> TimeInterval {
        try phrases.reduce(0) { try $0 + seconds($1) }
    }

    /// The step before can run on under this one, by as much as triage's question has left when the
    /// first tap the panel takes lands, 0.6 s in. Measured, since the wording and the voice both change.
    private func overhang() throws -> TimeInterval { try seconds("triage_ask") - 0.6 }

    /// A timer that outruns the speech takes the step's card off screen mid-sentence, and a tap aimed
    /// at its Done button lands on the next step's answers.
    @Test(.enabled(if: Self.clipsRendered)) func everyTimedStepOutlastsItsOwnLines() throws {
        let overhang = try overhang()
        for state in try loadMergedBundle().definition.states where state.kind.isAwake {
            guard let timeout = state.timeout else { continue }
            let said = try speech(state.entryPhrases)
            #expect(said + overhang < timeout.seconds, "\(state.id): \(said) s of speech, \(timeout.seconds) s step")
        }
    }

    /// The answer has to fit between the end of the question and its first repeat or the timer, with
    /// what the tap kept still ahead of it. The aspirin question is the worst case: a first tap on the
    /// longest step.
    @Test(.enabled(if: Self.clipsRendered)) func aQuestionLeavesTimeToAnswerIt() throws {
        func asksAgain(_ state: StateDefinition) -> TimeInterval? {
            let repeats = state.repeating.filter { state.entryPhrases.contains($0.phrase) }.map(\.everySeconds)
            return (repeats + [state.timeout?.seconds].compactMap { $0 }).min()
        }
        let states = try loadMergedBundle().definition.states
        let call = try #require(states.first { $0.id == "chest_call" })
        let check = try #require(states.first { $0.id == "chest_aspirin_check" })
        let kept = try speech(call.entryPhrases) - 0.6
        let window = try #require(asksAgain(check)) - kept - speech(check.entryPhrases)
        // The 10 s repeat starts at entry, so a 5.2 s question after a kept chest_call can come round
        // again before anyone could answer it. Known until the repeat or the wording changes.
        withKnownIssue("aspirin_check repeats before there is time to answer it", isIntermittent: true) {
            #expect(window >= 4, "\(window) s to answer")
        }

        for state in states where state.kind.isAwake && state.question != nil {
            let window = try #require(asksAgain(state)) - speech(state.entryPhrases)
            if state.id == check.id {
                withKnownIssue("aspirin_check is 5.2 s of a 10 s repeat", isIntermittent: true) {
                    #expect(window >= 5, "\(state.id): \(window) s to answer")
                }
            } else {
                #expect(window >= 5, "\(state.id): \(window) s to answer")
            }
        }
    }

    // MARK: - What the files have to carry

    private func modules() throws -> [(id: String, module: ScenarioModule)] {
        try ScenarioModule.manifest.map { id in
            let url = repoRoot().appendingPathComponent("clinical/modules/\(id).json")
            return (id, try ProtocolBundle.clinicalDecoder().decode(ScenarioModule.self, from: Data(contentsOf: url)))
        }
    }

    /// `FlowExplanation` says DRAFT as a literal, so signing a module has to come back and change it.
    @Test func everythingStaysMarkedDraft() throws {
        for (id, module) in try modules() {
            #expect(module.status == "DRAFT", "\(id)")
            #expect(module.reviewer == nil, "\(id)")
        }
    }

    @Test func everyPhraseFitsAndEverythingIsCited() throws {
        for (id, module) in try modules() {
            for phrase in module.phrases {
                let words = phrase.text.split(separator: " ").count
                #expect(words <= 14, "\(id) \(phrase.id) has \(words) words")
                #expect(!phrase.citation.isEmpty, "\(id) \(phrase.id)")
            }
            for state in module.states {
                #expect(!state.citation.isEmpty, "\(id) \(state.id)")
            }
        }
    }

    /// The approved table, word for word, so an edit can't quietly change what gets said.
    @Test(arguments: [
        ("triage_ask", "Tell me what's happening, or tap below.", "Project"),
        ("triage_recheck", "Call 911 if unsure. If they stop responding, tap Not responding now.", "Project proposal, needs clinician approval. The static card's call prompt and re-check, for a Yes that was a mis-tap"),
        ("general_intro", "Call 911. Follow the dispatcher. Stay with them.", "Project"),
        ("choking_steps", "Can't cough or speak? Call 911. Give back slaps, then abdominal thrusts.", "ILCOR 2025, weak"),
        ("chest_possible", "Possible heart attack.", "AHA 2024, 1 C-LD"),
        ("chest_sit", "Sit them comfortably. Cushion behind their back.", "AHA/Red Cross First Aid 2024, positioning, COR 1 C-EO. St John Ambulance, heart attack, cushions behind them. The cushion is a proposal"),
        ("aspirin_check", "Any aspirin allergy, injury, doctor's warning, or not fully alert?", "AHA 2024, 2b B-NR"),
        ("aspirin_give", "Chew and swallow one 325 mg aspirin, or two 81 mg.", "AHA 2024, 2b B-NR, 162-325 mg"),
        ("aspirin_skip", "No aspirin. Wait for EMS.", "AHA 2024, 2b C-EO"),
        ("aspirin_stop", "Do not give aspirin. Wait for EMS.", "AHA 2024, 2b B-NR"),
        ("chest_wait_line", "Stay with them until EMS arrives. If they collapse, tap Not responding now.", "AHA 2024, 1 C-LD, plus project"),
        ("aed_look", "Sweep the phone around. Look for an AED, in case they collapse.", "Project"),
        ("aed_found", "If there's an AED, have someone bring it. Follow the arrow if it shows.", "Project"),
        ("limb_possible", "Possible broken bone. Keep it as found.", "AHA 2024, 2b C-EO"),
        ("limb_danger_ask", "Heavy bleeding? Neck or back pain? Limb blue or pale?", "AHA 2024, 1 C-EO"),
        ("limb_danger_care", "Press hard on any bleeding, cloth if handy. Keep them still.", "AHA 2024, 1 C-LD and 1 C-EO. The cloth is a proposal, after ACS Stop the Bleed"),
        ("limb_tourniquet", "If pressure does not stop it, tighten a tourniquet above the wound.", "AHA 2024, 1 B-NR"),
        ("limb_gloves", "Put gloves on only if they're in reach. Don't delay pressure.", "American Red Cross First Aid/CPR/AED: gloves if available, never delay care for them. Proposal, needs clinician approval"),
        ("limb_wound", "Cover open wounds with clean cloth.", "AHA 2024, 2b C-EO. Cloth for a dressing is a proposal"),
        ("limb_support", "Don't straighten it. Pad under it: towel, pillow.", "AHA 2024, 2a C-EO, and position found 2b C-EO. Materials are a proposal"),
        ("limb_seek_care", "They need medical care. Call 911 if unsure or it gets worse.", "AHA 2024, 1 C-EO"),
    ])
    func thePhraseTableIsVerbatim(id: String, text: String, citation: String) throws {
        let phrase = try #require(try loadMergedBundle().phrases.phrases.first { $0.id == id }, "\(id)")
        #expect(phrase.text == text)
        #expect(phrase.citation == citation)
    }

    @Test(arguments: [
        ("correct_diagnosis", "Correction. That is only a possibility. Only a clinician can say."),
        ("correct_identity", "Correction. I am an AI, not a doctor or nurse."),
        ("correct_awake", "Correction. I'm not sure about that. Follow the dispatcher."),
    ])
    func theCorrectionsAreVerbatim(id: String, text: String) throws {
        #expect(try loadMergedBundle().text(forPhrase: id) == text)
    }
}
