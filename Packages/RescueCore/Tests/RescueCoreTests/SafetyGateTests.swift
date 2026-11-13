import Foundation
import Testing
@testable import RescueCore

@Suite struct SafetyGateTests {
    private func engine() throws -> ProtocolEngine { ProtocolEngine(bundle: try loadBundle()) }

    @Test func staleVersionIsRejected() throws {
        var session = Session(engine: try engine())
        let old = session.proposal(.reportFinding(.notBreathing, source: .seen, confidence: .high))
        session.human(.no)
        let stateID = session.state.stateID
        session.send(.model(old))
        #expect(session.state.stateID == stateID)
        #expect(session.log.entries.last?.detail.hasSuffix("stale_version") == true)
    }

    @Test func expiredProposalIsRejected() throws {
        var session = Session(engine: try engine())
        let old = session.proposal(.reportFinding(.notBreathing, source: .seen, confidence: .high))
        session.now += 6
        session.send(.model(old))
        #expect(session.state.stateID == "intake_responsive")
        #expect(session.log.entries.last?.detail.hasSuffix("expired") == true)
    }

    @Test func sayRespectsAllowlistAndCooldown() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        session.model(.say(phraseID: "correct_stop"))
        #expect(session.phrases.isEmpty)
        #expect(session.log.entries.last?.detail.hasSuffix("phrase_not_allowed") == true)

        session.model(.say(phraseID: "no_pulse_check"))
        #expect(session.phrases == ["no_pulse_check"])
        session.model(.say(phraseID: "no_pulse_check"))
        #expect(session.phrases.isEmpty)
        #expect(session.log.entries.last?.detail.hasSuffix("cooldown") == true)
        session.now += 21
        session.model(.say(phraseID: "no_pulse_check"))
        #expect(session.phrases == ["no_pulse_check"])
    }

    @Test func locateOnlyWhereFramesAreAllowed() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        session.model(.locateObject(.aed))
        #expect(!session.effects.contains(.locate(.aed)))
        session.human(.scan)
        session.model(.locateObject(.aed))
        #expect(session.effects.contains(.locate(.aed)))
    }

    @Test func resourcesHintOnceAndNeverChangeState() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        let version = session.state.version
        session.model(.reportResources([.aed, .gloves]))
        #expect(session.phrases == ["aed_spotted"])
        #expect(session.state.version == version)
        session.model(.reportResources([.aed]))
        #expect(session.phrases.isEmpty)
    }

    @Test func secondPersonGetsAssignedARole() throws {
        var session = Session(engine: try engine())
        session.human(.secondPerson)
        #expect(session.phrases == ["assign_helper"])
        #expect(session.state.resources.contains(.secondPerson))
    }

    @Test func dispatcherFindingQuietsTheModelAndNothingElse() throws {
        let engine = try engine()
        var session = Session(engine: engine)
        session.goToCompressions()
        session.modelFinding(.dispatcherSpeaking)
        #expect(session.state.stateID == "compressions")
        #expect(session.state.metronomeOn)
        #expect(session.effects.contains(.flushModelAudio))
        #expect(!session.effects.contains(.pauseAudio(seconds: 8)))
    }

    /// Authority order: the dispatcher and the AED both outrank the model.
    @Test func sayIsRejectedWhileAnythingHoldsTheFloor() throws {
        let engine = try engine()
        let holds: [(String, (inout Session) -> Void)] = [
            ("aed report", { $0.modelFinding(.aedPrompting) }),
            ("dispatcher report", { $0.modelFinding(.dispatcherSpeaking) }),
            ("aed keyword", { $0.send(.keyword(.aedTalking)) }),
            ("dispatcher keyword", { $0.send(.keyword(.dispatcherTalking)) }),
            ("dispatcher sheet", { $0.human(.dispatcherOn) }),
            ("call", { $0.send(.callChanged(active: true)) }),
            ("flagged line", { $0.send(.sentinelFlag(SentinelFlag(category: .pulseCheck, excerpt: "x"))) }),
        ]
        for (name, hold) in holds {
            var session = Session(engine: engine)
            session.goToCompressions()
            hold(&session)
            session.model(.say(phraseID: "keep_going"))
            #expect(session.phrases.isEmpty, "\(name)")
            #expect(session.entries(.proposalRejected).last?.detail.hasSuffix("speech_held") == true, "\(name)")
        }
    }

    /// The dispatcher's hold outlasts the 8 s ones that start with it.
    @Test func aDispatcherHeardKeepsTheFloorAfterTheShorterHoldsLapse() throws {
        let engine = try engine()
        var session = Session(engine: engine)
        session.human(.unsure)
        session.human(.called)
        session.human(.done)
        #expect(engine.policy(for: session.state, at: session.now).modelSpeechOpen)

        session.modelFinding(.dispatcherSpeaking)
        session.now += 9
        session.send(.tick)
        #expect(session.state.modelSpeechHoldUntil == nil)
        #expect(!engine.policy(for: session.state, at: session.now).modelSpeechOpen)
        session.model(.say(phraseID: "no_pulse_check"))
        #expect(session.phrases.isEmpty)
        #expect(session.entries(.proposalRejected).last?.detail.hasSuffix("speech_held") == true)
    }

    @Test func sayWorksAgainOnceTheHoldLapses() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        session.modelFinding(.dispatcherSpeaking)
        session.advance(31)
        session.model(.say(phraseID: "keep_going"))
        #expect(session.phrases == ["keep_going"])
    }

    @Test func aResourceHintObeysTheAllowlistAndTheFloor() throws {
        let engine = try engine()
        var scan = Session(engine: engine)
        scan.goToCompressions()
        scan.human(.scan)
        scan.model(.reportResources([.aed]))
        #expect(scan.phrases == ["aed_spotted"])

        var held = Session(engine: engine)
        held.goToCompressions()
        held.modelFinding(.dispatcherSpeaking)
        held.model(.reportResources([.aed]))
        #expect(held.phrases.isEmpty, "the dispatcher has the floor")
        #expect(held.state.resources.contains(.aed), "but the resource still counts")
    }

    /// "Keep pushing" means nothing to someone not pushing.
    @Test func noResourceHintPlaysWhereTheStateCouldNotSayIt() throws {
        let engine = try engine()
        let awake: (inout Session) -> Void = { $0.human(.yes) }
        let special: (inout Session) -> Void = { $0.human(.notAdult) }
        let intake: (inout Session) -> Void = { _ in }
        for walk in [awake, special, intake] {
            var session = Session(engine: engine)
            walk(&session)
            session.model(.reportResources([.aed]))
            #expect(session.phrases.isEmpty, "\(session.state.stateID)")
            #expect(session.state.resources.contains(.aed))
        }
    }

    @Test func aFlagOnALineNobodyHeardGetsNoCorrection() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        session.advance(SafetyGate.heardGrace)
        session.send(.sentinelFlag(SentinelFlag(category: .stopCpr, excerpt: "stop pushing")))
        #expect(session.phrases.isEmpty, "the gate has been closed a while, so this audio was dropped")
        #expect(session.effects.contains(.flushModelAudio))
        #expect(session.entries(.sentinelFlag).count == 1, "it still shows on the panel")
    }

    @Test func aFlagJustAfterTheGateClosedStillGetsACorrection() throws {
        var session = Session(engine: try engine())
        session.human(.unsure)
        session.human(.called)
        session.human(.done)
        #expect(session.state.stateID == "place_hands")
        session.human(.done)
        #expect(session.state.stateID == "compressions")
        session.advance(2)
        session.send(.sentinelFlag(SentinelFlag(category: .pulseCheck, excerpt: "check his pulse")))
        #expect(session.phrases == ["correct_pulse"], "a transcript or audit lands after its audio")
    }

    @Test func aBurstOfFlagsGetsOneCorrection() throws {
        var session = Session(engine: try engine())
        session.human(.unsure)
        session.human(.called)
        session.human(.done)
        for category in SentinelFlag.Category.allCases {
            session.send(.sentinelFlag(SentinelFlag(category: category, excerpt: "x")))
            session.now += 1
        }
        let corrections = session.allPhrases.filter { $0.hasPrefix("correct_") }
        #expect(corrections.count == 1, "\(corrections)")
    }

    @Test func theSameCorrectionWaitsOutTheCooldown() throws {
        var session = Session(engine: try engine())
        let flag = SentinelFlag(category: .pulseCheck, excerpt: "x")
        session.send(.sentinelFlag(flag))
        #expect(session.phrases == ["correct_pulse"])
        session.advance(9) // past the hold, inside the cooldown
        session.send(.sentinelFlag(flag))
        #expect(session.phrases.isEmpty)
        session.advance(21)
        session.send(.sentinelFlag(flag))
        #expect(session.phrases == ["correct_pulse"])
    }

    @Test func correctionsDoNotPlayOnTheCards() throws {
        for action in [HumanAction.yes, .notAdult] {
            var session = Session(engine: try engine())
            session.human(action)
            session.send(.sentinelFlag(SentinelFlag(category: .deathStatement, excerpt: "x")))
            #expect(session.phrases.isEmpty, "\(session.state.stateID)")
        }
    }

    @Test func aBadLineHeardAtHandoffIsStillCorrected() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        session.human(.emsArrived)
        #expect(session.state.stateID == "handoff")
        session.send(.sentinelFlag(SentinelFlag(category: .reassurance, excerpt: "he's fine")))
        #expect(session.phrases == ["correct_reassure"], "the gate is open there")
    }

    @Test func sentinelFlagFlushesAndCorrects() throws {
        let engine = try engine()
        var session = Session(engine: engine)
        session.human(.unsure)
        session.human(.called)
        session.human(.done)
        #expect(engine.policy(for: session.state, at: session.now).modelSpeechOpen)
        session.send(.sentinelFlag(SentinelFlag(category: .pulseCheck, excerpt: "check his pulse")))
        #expect(session.effects.contains(.flushModelAudio))
        #expect(session.phrases == ["correct_pulse"])
        #expect(!engine.policy(for: session.state, at: session.now).modelSpeechOpen, "voice held after a flag")
        #expect(session.state.stateID == "place_hands", "a flag never changes the step")
    }

    /// The plan's M4 check: 10,000 hostile sessions, 0 illegal transitions.
    @Test func fuzzedModelCallsCauseNoIllegalTransitions() throws {
        let engine = try engine()
        let definition = engine.bundle.definition
        let urgency = Dictionary(uniqueKeysWithValues: definition.states.map { ($0.id, $0.urgency) })
        var rng = SplitMix64(state: 42)
        let phraseIDs = engine.bundle.phrases.phrases.map(\.id) + ["made_up", "stop_cpr"]

        func action() -> ModelProposal.Action {
            switch Int.random(in: 0..<5, using: &rng) {
            case 0: .reportFinding(Finding.allCases.randomElement(using: &rng)!, source: .seen, confidence: .high)
            case 1: .reportResources([Resource.allCases.randomElement(using: &rng)!])
            case 2: .say(phraseID: phraseIDs.randomElement(using: &rng)!)
            case 3: .locateObject(.aed)
            default: .logEvent(ModelNote.allCases.randomElement(using: &rng)!)
            }
        }

        for sessionIndex in 0..<10_000 {
            var session = Session(engine: engine)
            // Start half of the sessions already in CPR, where the stakes are highest.
            if sessionIndex % 2 == 0 { session.goToCompressions() }

            for _ in 0..<20 {
                let before = session.state
                let stale = Int.random(in: 0..<4, using: &rng) == 0
                let version = stale ? before.version - 1 : before.version
                session.send(.model(ModelProposal(action: action(), stateVersion: version, issuedAt: session.now)))

                let beforeUrgency = urgency[before.stateID]!
                let afterUrgency = urgency[session.state.stateID]!
                #expect(afterUrgency >= beforeUrgency, "\(before.stateID) to \(session.state.stateID)")
                if stale { #expect(session.state.stateID == before.stateID) }
                if beforeUrgency == 4 {
                    #expect(session.state.stateID == before.stateID, "model moved a CPR state")
                    #expect(session.state.metronomeOn == before.metronomeOn, "model changed the metronome")
                }
                #expect(!session.effects.contains(.metronome(on: false)), "model stopped the metronome")
                session.now += 1
            }
        }
    }

    @Test func fuzzedHumanAndTimeKeepMetronomeTrue() throws {
        let engine = try engine()
        let states = Dictionary(uniqueKeysWithValues: engine.bundle.definition.states.map { ($0.id, $0) })
        var rng = SplitMix64(state: 7)

        for _ in 0..<2_000 {
            var session = Session(engine: engine)
            for _ in 0..<40 {
                if Bool.random(using: &rng) {
                    session.human(HumanAction.allCases.randomElement(using: &rng)!)
                } else {
                    session.advance(Double.random(in: 0...15, using: &rng))
                }
                let definition = states[session.state.stateID]!
                if !definition.metronomeToggleable {
                    #expect(session.state.metronomeOn == (definition.metronome == .on), "\(definition.id)")
                }
                #expect(!session.state.recentlyPlayed.contains("made_up"))
            }
        }
    }

    @Test func replayIsDeterministic() throws {
        let engine = try engine()
        func run() -> (RescueState, EventLog) {
            var session = Session(engine: engine)
            session.human(.no)
            session.modelFinding(.abnormalBreathing)
            session.advance(5)
            session.advance(5)
            session.advance(5)
            session.advance(61)
            return (session.state, session.log)
        }
        let first = run()
        let second = run()
        #expect(first.0 == second.0)
        #expect(first.1 == second.1)
    }
}
