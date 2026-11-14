import Foundation
import Testing
@testable import RescueCore

/// Numbers match the invariants in SAFETY.md.
@Suite struct InvariantTests {
    private func engine() throws -> ProtocolEngine { ProtocolEngine(bundle: try loadBundle()) }
    private let cprUrgency = 4

    // 1. Only a human action leaves CPR.
    @Test func onlyHumansLeaveCpr() throws {
        let bundle = try loadBundle()
        let urgency = Dictionary(uniqueKeysWithValues: bundle.definition.states.map { ($0.id, $0.urgency) })
        for state in bundle.definition.states where state.urgency == cprUrgency {
            #expect(state.kind == .cpr, "\(state.id)")
            for transition in state.transitions where urgency[transition.to]! < cprUrgency {
                #expect(transition.on.hasPrefix("human."), "\(state.id) leaves CPR on \(transition.on)")
            }
            if let timeout = state.timeout { #expect(urgency[timeout.to] == cprUrgency, "\(state.id) times out of CPR") }
        }
    }

    // 2. Only the engine stops the metronome, and pads hand authority to the AED.
    @Test func metronomeRules() throws {
        let bundle = try loadBundle()
        var session = Session(engine: try engine())
        session.goToCompressions()
        #expect(session.state.metronomeOn)

        session.human(.metronomeOff)
        #expect(session.state.metronomeOn, "metronome can't be toggled during base compressions")

        session.human(.aedHere)
        #expect(session.state.metronomeOn)
        session.human(.padsOn)
        #expect(session.state.stateID == "aed_analyze")
        #expect(!session.state.metronomeOn, "metronome is off once pads are on")

        session.advance(60)
        #expect(!session.state.metronomeOn, "metronome must not resume on its own during analysis")

        session.human(.aedSaysCpr)
        #expect(session.state.stateID == "compressions_aed")
        #expect(!session.state.metronomeOn, "opt-in only after pads")
        session.human(.metronomeOn)
        #expect(session.state.metronomeOn)

        #expect(bundle.definition.states.filter(\.metronomeToggleable).map(\.id) == ["compressions_aed"])
    }

    @Test func keywordPausesAudioButNeverChangesState() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        let before = session.state.stateID
        let version = session.state.version
        session.send(.keyword(.aedTalking))
        #expect(session.state.stateID == before)
        #expect(session.state.version == version)
        #expect(session.state.metronomeOn, "pause is output only")
        #expect(session.effects.contains(.pauseAudio(seconds: 8)))
        session.advance(8)
        #expect(session.effects.contains(.resumeAudio))
    }

    // 3. Model or sensor events can raise urgency. Lowering requires a human.
    @Test func nothingAutomaticLowersUrgency() throws {
        let bundle = try loadBundle()
        let urgency = Dictionary(uniqueKeysWithValues: bundle.definition.states.map { ($0.id, $0.urgency) })
        for state in bundle.definition.states {
            for transition in state.transitions where transition.on.hasPrefix("model.") {
                #expect(urgency[transition.to]! >= state.urgency, "\(state.id): \(transition.on) lowers urgency")
            }
            if let timeout = state.timeout {
                #expect(urgency[timeout.to]! >= state.urgency, "\(state.id) timeout lowers urgency")
                if let rule = timeout.ifBreathsAtLeast {
                    #expect(urgency[rule.to]! >= state.urgency, "\(state.id) breath guard lowers urgency")
                }
            }
        }
    }

    @Test func modelCannotReportItsWayDown() throws {
        for finding in Finding.allCases where finding.wouldLowerUrgency {
            var session = Session(engine: try engine())
            session.human(.no) // to intake_breathing
            let stateID = session.state.stateID
            session.modelFinding(finding)
            #expect(session.state.stateID == stateID, "\(finding)")
            #expect(session.log.entries.contains { $0.kind == .proposalRejected })
            #expect(session.phrases == (finding == .breathingNormally ? ["confirm_by_tap"] : []))

            var cpr = Session(engine: try engine())
            cpr.goToCompressions()
            cpr.modelFinding(finding)
            #expect(cpr.state.stateID == "compressions", "\(finding)")
            #expect(cpr.state.metronomeOn)
            #expect(cpr.phrases.isEmpty, "a rejected report during CPR shows on the panel only")
        }
    }

    // 4. Every required step comes from a local phrase.
    @Test func everyStepHasALocalPhraseWithoutAnyModel() throws {
        var session = Session(engine: try engine())
        #expect(session.phrases == ["ask_responsive"])
        session.human(.no)
        #expect(session.phrases == ["ask_breathing"])
        session.human(.no)
        #expect(session.phrases == ["call_911"])
        session.human(.called)
        #expect(session.phrases == ["roll_flat"])
        session.human(.done)
        #expect(session.phrases == ["hands_center"])
        session.human(.done)
        #expect(session.phrases == ["start_compressions"])
        session.human(.aedHere)
        #expect(session.phrases == ["aed_on"])
        session.human(.done)
        #expect(session.phrases == ["pads_place"])
        session.human(.padsOn)
        #expect(session.phrases == ["aed_authority"])
    }

    @Test func coachingPromptsRepeat() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        session.advance(59)
        #expect(session.phrases.isEmpty)
        session.advance(1)
        #expect(session.phrases == ["push_hard"])
        session.advance(60)
        #expect(Set(session.phrases) == ["push_hard", "switch_compressors"])
    }

    /// Hands are on the chest in all of these. A rescuer doesn't get to rest because the state moved.
    @Test func everyCprStateWithHandsOnRepeatsTheCoachingPrompts() throws {
        let definition = try loadBundle().definition
        let expected: [String: TimeInterval] = ["push_hard": 60, "switch_compressors": 120]
        for id in ["compressions", "resource_scan", "aed_on", "pads", "compressions_aed"] {
            let state = try #require(definition.states.first { $0.id == id })
            let actual = Dictionary(uniqueKeysWithValues: state.repeating.map { ($0.phrase, $0.everySeconds) })
            #expect(actual == expected, "\(id)")
        }
    }

    @Test func coachingPromptsRunInTheStatesThatCanLastThatLong() throws {
        let walks: [(String, (inout Session) -> Void)] = [
            ("aed_on", { $0.goToCompressions(); $0.human(.aedHere) }),
            ("pads", { $0.goToCompressions(); $0.human(.aedHere); $0.human(.done) }),
            ("compressions_aed", { $0.goToAnalysis(); $0.human(.aedSaysCpr) }),
        ]
        for (id, walk) in walks {
            var session = Session(engine: try engine())
            walk(&session)
            #expect(session.state.stateID == id)
            session.advance(60)
            #expect(session.phrases == ["push_hard"], "\(id)")
            session.advance(60)
            #expect(Set(session.phrases) == ["push_hard", "switch_compressors"], "\(id)")
        }
    }

    @Test func analysisKeepsRemindingSoASilentAEDCannotStrandTheRescuer() throws {
        var session = Session(engine: try engine())
        session.goToAnalysis()
        session.advance(45)
        #expect(session.phrases == ["aed_reminder"])
        session.advance(45)
        #expect(session.phrases == ["aed_reminder"])
    }

    /// Start CPR is the fastest way in, and must not be a way around the call.
    @Test func everyStartCprTheRescuerCanReachPromptsTheCall() throws {
        let walks: [(String, (inout Session) -> Void)] = [
            ("intake_responsive", { _ in }),
            ("intake_breathing", { $0.human(.no) }),
            ("watch_breathing", { $0.human(.no); $0.human(.yes) }),
            ("watch_reask", { s in
                s.human(.no); s.human(.yes); s.human(.breathMarked); s.human(.breathMarked); s.advance(10)
            }),
            ("responsive_patient", { $0.human(.yes) }),
            ("call_911", { $0.human(.unsure) }),
            ("position_patient", { $0.human(.unsure); $0.human(.called) }),
            ("place_hands", { $0.human(.unsure); $0.human(.called); $0.human(.done) }),
        ]
        let withStartCpr = try loadBundle().definition.states.filter { $0.transition(on: "human.start_cpr") != nil }.map(\.id)
        #expect(Set(withStartCpr) == Set(walks.map(\.0)))

        for (id, walk) in walks {
            var session = Session(engine: try engine())
            walk(&session)
            #expect(session.state.stateID == id)
            session.human(.startCpr)
            #expect(session.state.stateID == "compressions", "\(id)")
            #expect(session.state.metronomeOn, "\(id): the beat doesn't wait for the talking")
            #expect(session.allPhrases.contains("call_911"), "\(id)")
            #expect(session.allPhrases.contains("hands_center"), "\(id)")
            #expect(!session.entries(.callPrompted).isEmpty, "\(id)")
        }
    }

    @Test func aStartCprThatPromptsTheCallDoesSoBeforeTheBeatInstruction() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        #expect(session.phrases == ["call_911", "hands_center", "start_compressions"])
    }

    @Test func resumingCprFromTheCardPromptsTheCall() throws {
        var session = Session(engine: try engine())
        session.human(.yes)
        session.human(.emsArrived)
        session.human(.resumeCpr)
        #expect(session.state.stateID == "compressions")
        #expect(session.phrases.contains("call_911"))
        #expect(!session.entries(.callPrompted).isEmpty)
    }

    /// Whatever people tap and however long they wait, nobody compresses without hearing the call.
    @Test func noRouteIntoCprSkipsTheCall() throws {
        let engine = try engine()
        let states = Dictionary(uniqueKeysWithValues: engine.bundle.definition.states.map { ($0.id, $0) })
        var rng = SplitMix64(state: 11)
        for _ in 0..<2_000 {
            var session = Session(engine: engine)
            for _ in 0..<40 {
                if Bool.random(using: &rng) {
                    session.human(HumanAction.allCases.randomElement(using: &rng)!)
                } else {
                    session.advance(Double.random(in: 0...15, using: &rng))
                }
                if states[session.state.stateID]!.kind == .cpr {
                    #expect(session.allPhrases.contains("call_911"), "\(session.state.stateID)")
                    #expect(!session.entries(.callPrompted).isEmpty, "\(session.state.stateID)")
                }
            }
        }
    }

    // 5. "Yes, breathing" never ends the flow.
    @Test func yesBreathingEntersWatchAndNoReplyGoesToCpr() throws {
        var session = Session(engine: try engine())
        session.human(.no)
        session.human(.yes)
        #expect(session.state.stateID == "watch_breathing")
        #expect(session.phrases == ["watch_intro"])

        session.advance(10)
        #expect(session.state.stateID == "call_911", "no marked breaths means CPR path")
    }

    @Test func enteringAWatchStatePromptsTheCall() throws {
        var session = Session(engine: try engine())
        session.human(.no)
        session.human(.yes)
        #expect(session.state.stateID == "watch_breathing")
        let intro = try #require(session.engine.bundle.text(forPhrase: "watch_intro"))
        #expect(intro.contains("Call 911"))
        #expect(session.entries(.callPrompted).count == 1)

        session.human(.breathMarked)
        session.human(.breathMarked)
        session.advance(10)
        #expect(session.state.stateID == "watch_reask")
        session.human(.yes)
        #expect(session.phrases == ["watch_intro"], "911 stays prompted through the loop")
    }

    /// Yes on a question lowers urgency, so nothing may suggest it unless it answers what was
    /// asked. Every pair of a lowering finding and an intake or watch state.
    @Test func confirmByTapPlaysOnlyWhenTheReportAnswersTheQuestion() throws {
        let walks: [(String, (inout Session) -> Void)] = [
            ("intake_responsive", { _ in }),
            ("intake_breathing", { $0.human(.no) }),
            ("watch_breathing", { $0.human(.no); $0.human(.yes) }),
            ("watch_reask", { s in
                s.human(.no); s.human(.yes); s.human(.breathMarked); s.human(.breathMarked); s.advance(10)
            }),
        ]
        let answers: [String: Finding] = [
            "intake_responsive": .responsive,
            "intake_breathing": .breathingNormally,
            "watch_reask": .breathingNormally,
        ]
        let definition = try loadBundle().definition
        #expect(Set(definition.states.filter { $0.kind == .intake || $0.kind == .watch }.map(\.id)) == Set(walks.map(\.0)))

        for (id, walk) in walks {
            for finding in Finding.allCases where finding.wouldLowerUrgency {
                var session = Session(engine: try engine())
                walk(&session)
                #expect(session.state.stateID == id)
                let state = session.state.stateID

                session.modelFinding(finding)
                #expect(session.state.stateID == state, "\(id) \(finding)")
                #expect(session.phrases == (answers[id] == finding ? ["confirm_by_tap"] : []), "\(id) \(finding)")
            }
        }
    }

    @Test func aReportThatDoesNotAnswerGetsTheQuestionAgainOnceItHasBeenHeard() throws {
        var session = Session(engine: try engine())
        session.modelFinding(.breathingNormally)
        #expect(session.phrases.isEmpty, "the question is still playing")

        session.send(.phrasePlayed("ask_responsive"))
        session.modelFinding(.breathingNormally)
        #expect(session.phrases == ["ask_responsive"])
        session.modelFinding(.patientMoving)
        #expect(session.phrases.isEmpty, "only once, on the say cooldown")
    }

    @Test func cardStatesKeepAsking() throws {
        let cards: [(HumanAction, String, String)] = [
            (.yes, "responsive_patient", "responsive_recheck"),
            (.notAdult, "special_patient", "special_recheck"),
        ]
        for (action, id, phrase) in cards {
            var session = Session(engine: try engine())
            session.human(action)
            #expect(session.state.stateID == id)
            for _ in 0..<120 {
                session.advance(30)
                #expect(session.phrases == [phrase], "\(id)")
            }
            #expect(session.state.stateID == id, "a card doesn't move on by itself")
        }
    }

    @Test func aMistakenSpecialCardGoesBackWithATap() throws {
        var session = Session(engine: try engine())
        session.human(.notAdult)
        session.human(.back)
        #expect(session.state.stateID == "intake_responsive")
        #expect(session.phrases == ["ask_responsive"])
    }

    @Test func oneMarkedBreathIsNotEnough() throws {
        var session = Session(engine: try engine())
        session.human(.no)
        session.human(.yes)
        session.human(.breathMarked)
        session.advance(10)
        #expect(session.state.stateID == "call_911")
    }

    @Test func markedBreathsLeadToAReaskThatWaitsForTheRescuer() throws {
        var session = Session(engine: try engine())
        session.human(.no)
        session.human(.yes)
        session.human(.breathMarked)
        session.human(.breathMarked)
        session.advance(10)
        #expect(session.state.stateID == "watch_reask")
        for _ in 0..<6 { session.advance(10) }
        #expect(session.state.stateID == "watch_reask", "no reply keeps asking, and never moves on")
        #expect(session.allPhrases.filter { $0 == "ask_still_breathing" }.count >= 6)
        session.human(.no)
        #expect(session.state.stateID == "call_911")
    }

    @Test func watchLoopRestartsTheCount() throws {
        var session = Session(engine: try engine())
        session.human(.no)
        session.human(.yes)
        session.human(.breathMarked)
        session.human(.breathMarked)
        session.advance(10)
        session.human(.yes)
        #expect(session.state.stateID == "watch_breathing")
        #expect(session.state.breathsMarked == 0)
        session.advance(10)
        #expect(session.state.stateID == "call_911")
    }

    // 6. Uncertainty, or no reply in 10 s, goes to CPR.
    /// No reply on a question still goes on towards CPR, as far as a step that needs a tap. Every
    /// state from there on has Start CPR, and no state with no reply ever lowers the urgency.
    /// Only the rescuer moves the rescue on. Silence leaves every step where it is, apart from the breath
    /// count and the aspirin dose step, and Start CPR is still one tap wherever it's offered.
    @Test func noReplyNeverMovesTheStep() throws {
        let definition = try loadBundle().definition
        let timed: Set<String> = ["watch_breathing"]
        #expect(Set(definition.states.filter { $0.timeout != nil }.map(\.id)).isSubset(of: timed))
        for state in definition.states where state.kind != .card && state.timeout == nil {
            var session = Session(engine: try engine())
            session.state.stateID = state.id
            session.state.enteredAt = session.now
            for _ in 0..<12 { session.advance(30) }
            #expect(session.state.stateID == state.id, "\(state.id) moved to \(session.state.stateID) with no reply")
            if state.transition(on: "human.start_cpr")?.to == "compressions" {
                session.human(.startCpr)
                #expect(session.state.stateID == "compressions", "one tap from \(state.id)")
            }
        }
    }

    @Test func uncertaintyTakesTheCprPath() throws {
        var first = Session(engine: try engine())
        first.human(.unsure)
        #expect(first.state.stateID == "call_911")

        var second = Session(engine: try engine())
        second.human(.no)
        second.human(.unsure)
        #expect(second.state.stateID == "call_911")
    }

    /// A question waits at most 30 s for an answer, and says itself again every 10 s while it waits.
    /// A question never answers itself: it waits for a tap or a word and says itself again every 10 s.
    @Test func intakeQuestionsNeverTimeOutAndTheQuestionRepeats() throws {
        for state in try loadBundle().definition.states where state.kind == .intake || state.kind == .watch {
            guard state.question != nil else {
                // The breath count after "yes, breathing" is the one watch with a clock, and it's 10 s.
                #expect((state.timeout?.seconds ?? .infinity) <= 10, "\(state.id)")
                continue
            }
            #expect(state.timeout == nil, "\(state.id) waits for the rescuer")
            let repeats = state.repeating.filter { state.entryPhrases.contains($0.phrase) }
            #expect(repeats.map(\.everySeconds) == [10], "\(state.id) repeats its question every 10 s")
        }
    }

    @Test func gaspingGoesToCprFromTheModelToo() throws {
        var session = Session(engine: try engine())
        session.modelFinding(.abnormalBreathing)
        #expect(session.state.stateID == "call_911")
        #expect(session.phrases == ["gasping_not_normal", "call_911"])
    }

    @Test func noPhraseAsksForAPulseCheck() throws {
        for phrase in try loadBundle().phrases.phrases where phrase.text.lowercased().contains("pulse") {
            #expect(phrase.text.contains("Do not check"), "\(phrase.id)")
        }
    }

    // 8. AR never gates anything.
    @Test func overlayStatesAdvanceWithoutAnyVisionInput() throws {
        var session = Session(engine: try engine())
        session.human(.unsure)
        session.human(.called)
        session.human(.done)
        #expect(session.state.stateID == "place_hands")
        #expect(session.effects.contains(.overlay(.chestCenter)))
        session.human(.done)
        #expect(session.state.stateID == "compressions")
        #expect(session.effects.contains(.overlay(nil)))
    }

    // 9. Dialing goes through an allowlist.
    @Test func dialPolicyRefusesEmergencyNumbers() {
        for number in ["911", "1911", "+1 911", "9-1-1", "112", "999", "000", "110", "119", "118", "933"] {
            #expect(DialPolicy.isEmergencyNumber(number), "\(number)")
            #expect(DialPolicy.dialURL(for: number, allowlist: [number]) == nil, "\(number)")
        }
    }

    @Test func dialPolicyRequiresTheAllowlist() {
        #expect(DialPolicy.dialURL(for: "+1 (415) 555-0100", allowlist: []) == nil)
        #expect(DialPolicy.dialURL(for: "+1 (415) 555-0100", allowlist: ["14155550100"])?.absoluteString == "tel:14155550100")
    }

    // 10. PPG is unreachable from any arrest state.
    @Test func ppgOnlyInTheAwakeCard() throws {
        let definition = try loadBundle().definition
        #expect(definition.states.filter(\.allowsPpg).map(\.id) == ["responsive_patient"])
    }

    @Test func awakeCardIsOnlyReachedByAHuman() throws {
        for state in try loadBundle().definition.states {
            for transition in state.transitions where transition.to == "responsive_patient" {
                #expect(transition.on.hasPrefix("human."), "\(state.id): \(transition.on)")
            }
            #expect(state.timeout?.to != "responsive_patient")
        }
    }

    // 11. Uplink rules.
    @Test func noFrameUplinkDuringPadsOrAnalysis() throws {
        let definition = try loadBundle().definition
        for id in ["pads", "aed_analyze", "compressions", "compressions_aed"] {
            #expect(definition.states.first { $0.id == id }?.frameUplink == false, "\(id)")
        }
    }

    @Test func noMicUplinkWhileADispatcherMayBeAudible() throws {
        let engine = try engine()
        var session = Session(engine: engine)
        #expect(engine.policy(for: session.state, at: session.now).micUplink)
        session.human(.dispatcherOn)
        let policy = engine.policy(for: session.state, at: session.now)
        #expect(!policy.micUplink)
        #expect(!policy.modelSpeechOpen)
        #expect(session.effects.contains(.flushModelAudio))
        session.human(.dispatcherOff)
        #expect(engine.policy(for: session.state, at: session.now).micUplink)
    }

    @Test func callForcesPlaybackOnly() throws {
        let engine = try engine()
        var session = Session(engine: engine)
        session.send(.callChanged(active: true))
        let policy = engine.policy(for: session.state, at: session.now)
        #expect(policy.audioMode == .playbackOnly)
        #expect(!policy.micUplink)
        #expect(!policy.frameUplink)
        #expect(!policy.modelSpeechOpen)
        // Guidance keeps going during the call.
        session.human(.startCpr)
        #expect(session.state.metronomeOn)
        session.send(.callChanged(active: false))
        #expect(engine.policy(for: session.state, at: session.now).audioMode == .full)
    }

    // A dispatcher that can be heard is as much a dispatcher as one on this phone.
    @Test func hearingADispatcherClosesTheMicForABoundedTime() throws {
        let engine = try engine()
        let seconds = engine.bundle.definition.dispatcherMicHoldSeconds
        let triggers: [(String, (inout Session) -> Void)] = [
            ("finding", { $0.modelFinding(.dispatcherSpeaking) }),
            ("keyword", { $0.send(.keyword(.dispatcherTalking)) }),
        ]
        for (name, trigger) in triggers {
            var session = Session(engine: engine)
            #expect(engine.policy(for: session.state, at: session.now).micUplink, "\(name)")

            trigger(&session)
            var published = session.effects.compactMap { effect -> RuntimePolicy? in
                if case let .policyChanged(policy) = effect { policy } else { nil }
            }
            #expect(published.last?.micUplink == false, "\(name): the closed mic is published")
            #expect(published.last?.modelSpeechOpen == false, "\(name)")
            #expect(session.state.stateID == "intake_responsive", "\(name) never changes state")

            session.advance(seconds - 0.1)
            #expect(!engine.policy(for: session.state, at: session.now).micUplink, "\(name)")

            session.advance(0.1)
            published = session.effects.compactMap { effect -> RuntimePolicy? in
                if case let .policyChanged(policy) = effect { policy } else { nil }
            }
            #expect(published.last?.micUplink == true, "\(name): it reopens by itself, and says so")
            #expect(engine.policy(for: session.state, at: session.now).micUplink, "\(name)")
        }
    }

    @Test func aDispatcherKeepsCompressionsGoing() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        session.modelFinding(.dispatcherSpeaking)
        #expect(session.state.stateID == "compressions")
        #expect(session.state.metronomeOn)
        session.advance(60)
        #expect(session.phrases == ["push_hard"], "protocol prompts don't depend on the mic")
    }

    // Speech gate table.
    @Test func speechGateClosedWhereItMustBe() throws {
        let open = try loadBundle().definition.speechGate.openStates
        for id in ["compressions", "compressions_aed", "pads", "aed_analyze", "aed_on", "call_911", "responsive_patient", "watch_breathing", "watch_reask"] {
            #expect(!open.contains(id), "\(id) must stay closed")
        }
    }

    // The side effects of moving, which everything downstream relies on.
    @Test func enteringAnyStateFlushesPublishesAndBriefs() throws {
        let engine = try engine()
        var rng = SplitMix64(state: 3)
        for _ in 0..<500 {
            var session = Session(engine: engine)
            for _ in 0..<30 {
                let before = session.state.version
                if Bool.random(using: &rng) {
                    session.human(HumanAction.allCases.randomElement(using: &rng)!)
                } else {
                    session.advance(Double.random(in: 0...15, using: &rng))
                }
                guard session.state.version != before else { continue }
                #expect(session.effects.contains(.flushModelAudio), "\(session.state.stateID)")
                #expect(session.effects.contains { if case .policyChanged = $0 { true } else { false } }, "\(session.state.stateID)")
                #expect(session.effects.contains { if case let .sendStateBrief(brief) = $0 { brief.version == session.state.version } else { false } })
            }
        }
    }

    @Test func aCallFlushesAndPublishes() throws {
        var session = Session(engine: try engine())
        session.send(.callChanged(active: true))
        #expect(session.effects.contains(.flushModelAudio))
        #expect(session.effects.contains { if case let .policyChanged(policy) = $0 { policy.audioMode == .playbackOnly } else { false } })
        session.send(.callChanged(active: false))
        #expect(session.effects.contains { if case let .policyChanged(policy) = $0 { policy.audioMode == .full } else { false } })
    }

    @Test func aKeywordClosesModelSpeechUntilTheAudioResumes() throws {
        let engine = try engine()
        var session = Session(engine: engine)
        #expect(engine.policy(for: session.state, at: session.now).modelSpeechOpen)
        session.send(.keyword(.aedTalking))
        #expect(!engine.policy(for: session.state, at: session.now).modelSpeechOpen)
        session.advance(8)
        #expect(engine.policy(for: session.state, at: session.now).modelSpeechOpen)
    }

    @Test func shockMarksOnlyCountOnceTheAEDIsOn() throws {
        let engine = try engine()
        for state in engine.bundle.definition.states {
            var session = Session(engine: engine)
            session.state.stateID = state.id
            session.human(.shockDelivered)
            let accepted = !session.entries(.shockMarked).isEmpty
            #expect(accepted == (state.id == "aed_analyze" || state.id == "compressions_aed"), "\(state.id)")
        }
    }

    @Test func modelNotesAreTaggedAsInferred() throws {
        var session = Session(engine: try engine())
        session.model(.logEvent(.vomiting))
        let note = try #require(session.entries(.modelNote).last)
        #expect(note.source == .aiInferred)
        #expect(note.detail == "vomiting")
    }
}
