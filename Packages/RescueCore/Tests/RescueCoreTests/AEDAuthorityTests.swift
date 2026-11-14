import Foundation
import Testing
@testable import RescueCore

/// SAFETY.md: "Once pads are on, it is off by default and the AED is the authority."
@Suite struct AEDAuthorityTests {
    private func engine() throws -> ProtocolEngine { ProtocolEngine(bundle: try loadBundle()) }

    // MARK: - Nothing from the model talks over the analysis

    @Test func noModelOrSentinelEventMakesThePhoneTalkDuringAnalysis() throws {
        let engine = try engine()
        var events: [(inout Session) -> Void] = []
        for finding in Finding.allCases { events.append { $0.modelFinding(finding) } }
        for resource in Resource.allCases { events.append { $0.model(.reportResources([resource])) } }
        for phrase in engine.bundle.phrases.phrases { events.append { $0.model(.say(phraseID: phrase.id)) } }
        for category in SentinelFlag.Category.allCases {
            events.append { $0.send(.sentinelFlag(SentinelFlag(category: category, excerpt: "You can stop pushing now"))) }
        }
        events.append { $0.model(.logEvent(.other)) }
        events.append { $0.model(.locateObject(.aed)) }

        for event in events {
            var session = Session(engine: engine)
            session.goToAnalysis()
            event(&session)
            #expect(session.state.stateID == "aed_analyze")
            #expect(session.phrases.isEmpty, "\(session.phrases)")
        }
    }

    /// The scenario from the review, end to end. The AED is reported after a person said it was here.
    @Test func aReportOfTheAEDPlaysNoHintOncePadsAreOn() throws {
        var session = Session(engine: try engine())
        session.goToAnalysis()
        session.model(.reportResources([.aed]))
        #expect(session.phrases.isEmpty)
        #expect(session.state.resources.contains(.aed))
    }

    /// Also if the AED was first mentioned here, so the resource is new.
    @Test func aNewResourceDuringAnalysisPlaysNoHint() throws {
        var session = Session(engine: try engine())
        session.goToAnalysis()
        session.state.resources = []
        session.model(.reportResources([.aed, .secondPerson]))
        #expect(session.phrases.isEmpty)
    }

    @Test func aPersonTappingForAHelperStaysSilentDuringAnalysisAndElsewhereDoesNot() throws {
        var session = Session(engine: try engine())
        session.goToAnalysis()
        session.human(.secondPerson)
        #expect(session.phrases.isEmpty)
        #expect(session.state.resources.contains(.secondPerson))

        var before = Session(engine: try engine())
        before.goToCompressions()
        before.human(.secondPerson)
        #expect(before.phrases == ["assign_helper"])
    }

    @Test func analysisIsTheOneStateWhereTheAEDHasTheFloor() throws {
        let bundle = try loadBundle()
        let analysis = try #require(bundle.definition.states.first { $0.id == "aed_analyze" })
        #expect(analysis.allowedSay.isEmpty)
        #expect(analysis.aedHasAuthority)
        #expect(bundle.definition.states.filter(\.aedHasAuthority).map(\.id) == ["aed_analyze"])
    }

    // MARK: - Prompts on re-entry

    @Test func reenteringAnalysisRestartsItsReminder() throws {
        var session = Session(engine: try engine())
        session.goToAnalysis()
        session.now += 10
        session.human(.aedSaysCpr)
        session.advance(110) // about two minutes on, the AED reanalyzes
        session.human(.aedAnalyzing)
        #expect(session.state.stateID == "aed_analyze")

        session.advance(0.2)
        #expect(session.phrases.isEmpty, "the analysis has only just begun")
        session.advance(44)
        #expect(session.phrases.isEmpty)
        session.advance(0.8)
        #expect(session.phrases == ["aed_reminder"])
    }

    @Test func resumingAfterAnalysisDoesNotFireOverdueCoachingPrompts() throws {
        var session = Session(engine: try engine())
        session.goToAnalysis()
        session.advance(200)
        session.human(.aedSaysCpr)
        session.advance(0.2)
        #expect(session.phrases.isEmpty, "push_hard and switch_compressors weren't running in analysis")
        session.advance(59.8)
        #expect(session.phrases == ["push_hard"])
    }

    @Test func coachingPromptsRunOnAcrossTheStatesThatShareThem() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        session.advance(50)
        session.human(.scan)
        session.advance(9)
        #expect(session.phrases.isEmpty)
        session.advance(1)
        #expect(session.phrases == ["push_hard"], "60 s from the last one, not from the scan")
    }

    // MARK: - Queued speech

    @Test func enteringAnalysisCutsPhrasesBeforeItsOwn() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        session.human(.aedHere)
        session.human(.padsOn)
        let cut = try #require(session.effects.firstIndex(of: .cutPhrases))
        let authority = try #require(session.effects.firstIndex(of: .playPhrase("aed_authority")))
        #expect(cut < authority)
        #expect(session.effects.firstIndex(of: .metronome(on: false)).map { $0 < authority } == true)
    }

    @Test func aTapDropsStaleQueuedPhrasesButNotTheCallBeforeTheNewOnes() throws {
        var session = Session(engine: try engine())
        session.human(.no)
        let drop = try #require(session.effects.firstIndex(of: .dropQueuedPhrases(keeping: ["call_911", "calling_911"])))
        let ask = try #require(session.effects.firstIndex(of: .playPhrase("ask_breathing")))
        #expect(drop < ask)
    }

    @Test func aStartCprDropsBeforeItsCallPrompt() throws {
        var session = Session(engine: try engine())
        session.human(.startCpr)
        let drop = try #require(session.effects.firstIndex(of: .dropQueuedPhrases(keeping: ["call_911", "calling_911"])))
        let call = try #require(session.effects.firstIndex(of: .playPhrase("calling_911")))
        #expect(drop < call)
    }

    /// Positioning only announces the call, which the 911 agent places in the background, so Done there
    /// answers "Roll them flat": that line goes, and the short announcement may finish.
    @Test func doneOnPositioningDropsItsOwnLineButNotTheCall() throws {
        var session = Session(engine: try engine())
        session.human(.unsure)
        #expect(session.state.stateID == "position_patient")
        session.human(.done)
        #expect(session.effects.contains(.dropQueuedPhrases(keeping: ["call_911", "calling_911"])))
    }

    @Test func tappingPastTheStepAfterTheCallKeepsItsPrompt() throws {
        var session = Session(engine: try engine())
        session.human(.unsure)
        session.human(.done)
        session.human(.done)
        #expect(session.effects.contains(.dropQueuedPhrases(keeping: ["call_911", "calling_911"])))
    }

    @Test func aModelTransitionDropsStaleQuestions() throws {
        var session = Session(engine: try engine())
        session.modelFinding(.notBreathing)
        #expect(session.state.stateID == "position_patient")
        let drop = try #require(session.effects.firstIndex(of: .dropQueuedPhrases(keeping: ["call_911", "calling_911"])))
        let call = try #require(session.effects.firstIndex(of: .playPhrase("calling_911")))
        #expect(drop < call)
    }

    /// With nobody touching the phone, every required step must play, so nothing is ever stale.
    @Test func aRepeatDropsNothing() throws {
        var session = Session(engine: try engine())
        for _ in 0..<6 {
            session.advance(10)
            let drops = session.effects.contains {
                if case .dropQueuedPhrases = $0 { true } else { $0 == .cutPhrases }
            }
            #expect(!drops, "\(session.state.stateID)")
        }
        #expect(session.state.stateID == "intake_responsive")
        #expect(session.allPhrases.filter { $0 == "ask_responsive" }.count >= 6, "at 0 s, then every 10 s")
    }

    // MARK: - Pads stay on

    @Test func padsStayOnThroughEveryRouteBack() throws {
        typealias Walk = (inout Session) -> Void
        let routes: [(String, Walk)] = [
            ("mistaken EMS, then resume", { $0.human(.emsArrived); $0.human(.resumeCpr) }),
            ("patient moved, then no reply", { s in
                s.human(.patientMoving); s.advance(30)
            }),
            ("patient moved, then start cpr", { $0.human(.patientMoving); $0.human(.startCpr) }),
            ("patient moved, marks, re-ask says no", { s in
                s.human(.patientMoving); s.human(.breathMarked); s.human(.breathMarked); s.advance(10); s.human(.no)
            }),
            ("patient moved, marks, re-ask unsure", { s in
                s.human(.patientMoving); s.human(.breathMarked); s.human(.breathMarked); s.advance(10); s.human(.unsure)
            }),
            ("patient awake, then start cpr", { s in
                s.human(.patientMoving); s.human(.patientAwake); s.human(.startCpr)
            }),
            ("patient awake, then gasping", { s in
                s.human(.patientMoving); s.human(.patientAwake); s.modelFinding(.abnormalBreathing)
            }),
            ("patient awake, then not responding, then no", { s in
                s.human(.patientMoving); s.human(.patientAwake); s.human(.patientUnresponsive); s.human(.no)
            }),
        ]
        for (name, walk) in routes {
            var session = Session(engine: try engine())
            session.goToAnalysis()
            session.human(.aedSaysCpr)
            walk(&session)
            #expect(session.state.stateID == "compressions_aed", "\(name) reached \(session.state.stateID)")
            #expect(!session.state.metronomeOn, "\(name)")
            #expect(session.effects.contains(.playPhrase("resume_compressions")), "\(name)")
            #expect(!session.effects.contains(.playPhrase("roll_flat")), "\(name)")
            #expect(!session.effects.contains(.playPhrase("call_911")), "\(name)")
        }
    }

    /// Every human and timeout path, from any point after pads.
    @Test func theMetronomeNeverComesBackUnlessToggled() throws {
        let engine = try engine()
        let states = Dictionary(uniqueKeysWithValues: engine.bundle.definition.states.map { ($0.id, $0) })
        var rng = SplitMix64(state: 23)
        for _ in 0..<3_000 {
            var session = Session(engine: engine)
            session.goToAnalysis()
            var toggledOn = false
            for _ in 0..<40 {
                let before = session.state.stateID
                let action = HumanAction.allCases.randomElement(using: &rng)!
                if Bool.random(using: &rng) {
                    session.human(action)
                    if action == .metronomeOn, states[before]!.metronomeToggleable { toggledOn = true }
                    if action == .metronomeOff, states[before]!.metronomeToggleable { toggledOn = false }
                } else {
                    session.advance(Double.random(in: 0...15, using: &rng))
                }
                if session.state.stateID != before { toggledOn = false }
                #expect(session.state.padsOn)
                #expect(session.state.metronomeOn == toggledOn, "\(before) to \(session.state.stateID)")
                #expect(states[session.state.stateID]!.metronome == .off, "\(session.state.stateID) has a beat")
            }
        }
    }

    @Test func padsAreForgottenOnlyByANewRescue() throws {
        let engine = try engine()
        var session = Session(engine: engine)
        #expect(!session.state.padsOn)
        session.goToAnalysis()
        #expect(session.state.padsOn)
        session.human(.emsArrived)
        #expect(session.state.padsOn)
        #expect(!Session(engine: engine).state.padsOn)
    }

    // MARK: - Told that the AED is talking

    /// Eval row 18.
    @Test func hearingTheAEDPausesAudioWithoutLeavingTheStep() throws {
        let engine = try engine()
        for id in ["aed_on", "pads"] {
            var session = Session(engine: engine)
            session.goToCompressions()
            session.human(.aedHere)
            if id == "pads" { session.human(.done) }
            let version = session.state.version

            session.modelFinding(.aedPrompting)

            #expect(session.state.stateID == id)
            #expect(session.state.version == version)
            #expect(session.state.metronomeOn, "the engine's beat keeps its place, only output pauses")
            #expect(session.effects.contains(.pauseAudio(seconds: 8)))
            #expect(session.state.audioPausedFor == .aedTalking)
            #expect(session.entries(.audioPaused).last?.source == .aiInferred)
            #expect(session.state.modelSpeechHoldUntil != nil)

            session.advance(8)
            #expect(session.effects.contains(.resumeAudio))
            #expect(session.state.audioPausedFor == nil)
        }
    }

    @Test func aModelStuckOnThisCannotTakeTheBeatAway() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        var pauses = 0
        var silent: TimeInterval = 0
        // A stuck model repeating itself every second for ten minutes.
        for _ in 0..<600 {
            session.modelFinding(.aedPrompting)
            if session.effects.contains(.pauseAudio(seconds: 8)) { pauses += 1 }
            if session.state.audioPausedUntil != nil { silent += 1 }
            session.advance(1)
        }
        #expect(session.state.metronomeOn)
        #expect(pauses == 30, "once per 20 s")
        #expect(silent <= 600 * 0.45, "silent for \(silent) s of 600")
    }

    @Test func nowhereOutsideCprDoesAReportPauseAudio() throws {
        var session = Session(engine: try engine())
        session.modelFinding(.aedPrompting)
        #expect(!session.effects.contains(.pauseAudio(seconds: 8)))
        #expect(session.state.modelSpeechHoldUntil != nil)
    }

    @Test func theKeywordMarksTheAEDAsTalkingToo() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        session.send(.keyword(.aedTalking))
        #expect(session.state.audioPausedFor == .aedTalking)
        session.advance(8)
        #expect(session.state.audioPausedFor == nil)
    }

    @Test func aDispatcherKeywordIsNotTheAED() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        session.send(.keyword(.dispatcherTalking))
        #expect(session.state.audioPausedFor == .dispatcherTalking)
    }
}
