import Foundation
import Testing
@testable import RescueCore

/// The triage and heart attack modules as they ship, through the real engine.
@Suite struct HeartAttackFlowTests {
    private func engine() throws -> ProtocolEngine { ProtocolEngine(bundle: try loadMergedBundle()) }

    private func inTriage() throws -> Session {
        var session = Session(engine: try engine())
        session.human(.yes)
        return session
    }

    private func inFlow() throws -> Session {
        var session = try inTriage()
        session.human(.triageChest)
        return session
    }

    private func report(_ finding: Finding, _ confidence: Confidence, into session: inout Session) {
        session.model(.reportFinding(finding, source: .heard, confidence: confidence))
    }

    // MARK: - By taps

    @Test func yesReachesTriageAndAsksWithTheVoiceOpen() throws {
        let session = try inTriage()
        #expect(session.state.stateID == "triage")
        #expect(session.phrases == ["triage_ask"])
        #expect(session.engine.policy(for: session.state, at: session.now).modelSpeechOpen)
        #expect(session.entries(.answer).last?.detail == "responsive=yes")
        #expect(session.entries(.flowEntered).isEmpty)
    }

    @Test func theWholeFlowByTaps() throws {
        var session = try inFlow()
        let engine = session.engine
        #expect(session.state.stateID == "chest_call")
        #expect(session.phrases == ["chest_possible", "call_911", "chest_sit"])
        #expect(session.entries(.callPrompted).count == 1)
        #expect(session.entries(.flowEntered).map(\.detail) == ["possible_heart_attack"])
        #expect(session.entries(.flowEntered).last?.source == .bystander)
        #expect(!engine.policy(for: session.state, at: session.now).modelSpeechOpen)

        session.human(.done)
        #expect(session.state.stateID == "chest_aspirin_check")
        #expect(session.phrases == ["aspirin_check"])
        #expect(!engine.policy(for: session.state, at: session.now).modelSpeechOpen)

        session.human(.no)
        #expect(session.state.stateID == "chest_aspirin")
        #expect(session.phrases == ["aspirin_give"])
        #expect(session.entries(.answer).last?.detail == "aspirin_risk_reported=no")
        #expect(session.entries(.answer).last?.source == .bystander)
        #expect(session.entries(.aspirinAdvised).count == 1)
        #expect(!engine.policy(for: session.state, at: session.now).modelSpeechOpen)

        session.human(.done)
        #expect(session.state.stateID == "chest_wait")
        #expect(session.phrases == ["chest_wait_line"])
        #expect(engine.policy(for: session.state, at: session.now).modelSpeechOpen)

        session.human(.scan)
        #expect(session.state.stateID == "chest_scan")
        #expect(session.phrases == ["aed_look"])
        #expect(session.effects.contains(.overlay(.aedDevice)))
        #expect(!engine.policy(for: session.state, at: session.now).modelSpeechOpen)

        session.human(.done)
        #expect(session.state.stateID == "chest_wait")
        #expect(session.effects.contains(.overlay(nil)))
        #expect(session.entries(.flowEntered).count == 1, "one flow, however many steps")
    }

    /// Called answers the prompt. Done can land before it's been heard, on a step that doesn't open
    /// with it. Either way the step's other lines are required steps of their own.
    @Test(arguments: [
        (HumanAction.called, ["chest_possible", "chest_sit"]),
        (.done, ["call_911", "chest_possible", "chest_sit"]),
    ])
    func aTapKeepsWhatItDidNotAnswer(action: HumanAction, kept: [String]) throws {
        var session = try inFlow()
        session.human(action)
        #expect(session.state.stateID == "chest_aspirin_check")
        #expect(session.effects.contains(.dropQueuedPhrases(keeping: kept)), "\(session.effects)")
    }

    /// "Yes, there's a risk", and a stale tap under Done lands here too, on the safe branch.
    @Test(arguments: [HumanAction.yes, .unsure])
    func anythingButNoMeansNoAspirin(action: HumanAction) throws {
        var session = try inFlow()
        session.human(.done)
        session.human(action)
        #expect(session.state.stateID == "chest_wait")
        #expect(session.phrases == ["aspirin_skip", "chest_wait_line"])
        #expect(session.entries(.aspirinAdvised).isEmpty)
    }

    @Test func somethingElseGoesToGeneralTalkAndCountsAsACallPrompt() throws {
        var session = try inTriage()
        session.human(.triageOther)
        #expect(session.state.stateID == "general_talk")
        #expect(session.phrases == ["general_intro"])
        #expect(session.entries(.callPrompted).count == 1)
        #expect(session.engine.policy(for: session.state, at: session.now).modelSpeechOpen)
        #expect(session.entries(.flowEntered).isEmpty)
    }

    @Test func notThisGoesBackAndAskingAgainPlaysAgain() throws {
        var session = try inFlow()
        session.human(.done)
        session.human(.notThis)
        #expect(session.state.stateID == "triage")
        #expect(session.phrases == ["triage_ask"])
        #expect(!session.effects.contains(.cutPhrases))
    }

    @Test func theCardGainsTheWayIntoTriage() throws {
        var session = try inTriage()
        session.human(.patientUnresponsive)
        session.human(.yes)
        session.human(.patientAwake)
        #expect(session.state.stateID == "responsive_patient")
        #expect(session.phrases == ["responsive_card"])
        session.human(.triageOpen)
        #expect(session.state.stateID == "triage")
    }

    // MARK: - By silence

    /// No reply never moves on. The question repeats every 10 s until someone answers.
    @Test func silenceNeverGivesAspirin() throws {
        var session = try inFlow()
        session.advance(10)
        #expect(session.state.stateID == "chest_call", "the call step waits for Done or Called")
        #expect(session.phrases == ["chest_sit"])
        session.human(.done)
        #expect(session.state.stateID == "chest_aspirin_check")
        #expect(session.phrases == ["aspirin_check"])
        for _ in 0..<2 {
            session.advance(10)
            #expect(session.state.stateID == "chest_aspirin_check")
            #expect(session.phrases == ["aspirin_check"], "the question again, at 10 s and 20 s")
        }
        #expect(session.entries(.answer).filter { $0.detail.hasPrefix("aspirin") }.isEmpty, "silence isn't an answer")

        session.advance(600)
        #expect(session.state.stateID == "chest_aspirin_check")
        #expect(!session.allPhrases.contains("aspirin_give"))
        #expect(session.entries(.aspirinAdvised).isEmpty)
    }

    /// Nobody tapped past anything, so queued steps still play.
    @Test func noTouchKeepsTheCallPromptQueued() throws {
        var session = try inFlow()
        session.advance(15)
        #expect(!session.effects.contains { if case .dropQueuedPhrases = $0 { true } else { false } })
        #expect(!session.effects.contains(.cutPhrases))
    }

    /// The dose step keeps its timer, so it is never said twice. The scan waits, saying its line again.
    @Test func theAspirinStepEndsOnItsOwnAndTheScanWaits() throws {
        var aspirin = try inFlow()
        aspirin.human(.done)
        aspirin.human(.no)
        aspirin.advance(14)
        #expect(aspirin.state.stateID == "chest_aspirin")
        aspirin.advance(1)
        #expect(aspirin.state.stateID == "chest_wait")

        var scan = try inFlow()
        scan.human(.done)
        scan.human(.yes)
        scan.human(.scan)
        scan.advance(10)
        #expect(scan.state.stateID == "chest_scan")
        #expect(scan.phrases == ["aed_look"])
        scan.advance(600)
        #expect(scan.state.stateID == "chest_scan")
        scan.human(.done)
        #expect(scan.state.stateID == "chest_wait")
        #expect(aspirin.allPhrases.filter { $0 == "aspirin_give" }.count == 1, "the dose line never repeats")
    }

    @Test(arguments: [("triage", "triage_recheck"), ("general_talk", "general_intro"), ("chest_wait", "chest_wait_line")])
    func theOpenStatesReAskEveryThirtySecondsAndNeverMove(id: String, phrase: String) throws {
        var session = try inTriage()
        if id == "general_talk" { session.human(.triageOther) }
        if id == "chest_wait" {
            session.human(.triageChest)
            session.human(.done)
            session.human(.yes)
        }
        #expect(session.state.stateID == id)
        for _ in 0..<20 {
            session.advance(29)
            #expect(session.phrases.isEmpty, "\(id)")
            session.advance(1)
            #expect(session.phrases == [phrase], "\(id)")
            #expect(session.state.stateID == id)
        }
    }

    // MARK: - By report

    @Test(arguments: [
        ("triage", Finding.chestPain, "chest_call"),
        ("triage", .otherHeartSigns, "chest_call"),
        ("triage", .otherConcern, "general_talk"),
        ("triage", .choking, "choking_talk"),
        ("general_talk", .choking, "choking_talk"),
        ("general_talk", .chestPain, "chest_call"),
        ("general_talk", .otherHeartSigns, "chest_call"),
    ])
    func aSureEnoughReportRoutes(from: String, finding: Finding, to: String) throws {
        func start() throws -> Session {
            var session = try inTriage()
            if from == "general_talk" { session.human(.triageOther) }
            return session
        }

        var low = try start()
        let before = low.state
        report(finding, .low, into: &low)
        #expect(low.state == before, "below the edge's confidence it stays on the record only")
        #expect(low.entries(.observation).last?.detail == "\(finding.rawValue),heard,low")
        #expect(low.entries(.finding).isEmpty)
        #expect(low.effects.isEmpty)

        for confidence in [Confidence.medium, .high] {
            var session = try start()
            report(finding, confidence, into: &session)
            #expect(session.state.stateID == to)
            #expect(session.entries(.observation).last?.detail == "\(finding.rawValue),heard,\(confidence.rawValue)")
            #expect(session.entries(.finding).last?.detail == finding.rawValue)
        }
    }

    @Test func aReportedFlowIsRecordedAsTheAIs() throws {
        var session = try inTriage()
        session.modelFinding(.chestPain)
        #expect(session.entries(.flowEntered).map(\.detail) == ["possible_heart_attack"])
        #expect(session.entries(.flowEntered).last?.source == .aiInferred)
        #expect(session.phrases == ["chest_possible", "call_911", "chest_sit"])
    }

    /// Its own step, so the steps stay on screen and don't depend on the AI.
    @Test func chokingPlaysItsOwnStepsAtOnce() throws {
        var heard = try inTriage()
        heard.modelFinding(.choking)
        #expect(heard.state.stateID == "choking_talk")
        #expect(heard.phrases == ["choking_steps", "general_intro"])
        #expect(heard.entries(.callPrompted).count == 1)

        var tapped = try inTriage()
        tapped.human(.triageOther)
        tapped.human(.triageChoking)
        #expect(tapped.state.stateID == "choking_talk")
        #expect(tapped.phrases == ["choking_steps", "general_intro"])
        tapped.advance(29)
        #expect(tapped.phrases.isEmpty)
        tapped.advance(1)
        #expect(tapped.phrases == ["choking_steps"])
        tapped.advance(600)
        #expect(tapped.state.stateID == "choking_talk", "no reply never leaves for CPR here")
    }

    /// Someone talking in `general_talk` can still say their chest hurts or a limb is hurt, and nothing else moves it.
    @Test(arguments: [Finding.otherConcern, .aspirinUnsafe])
    func aFindingWithNoEdgeStaysAnObservation(finding: Finding) throws {
        var session = try inTriage()
        session.human(.triageOther)
        var before = session.state
        session.modelFinding(finding)
        before.aspirinRuledOut = finding == .aspirinUnsafe
        #expect(session.state == before)
        #expect(session.effects.isEmpty)
        #expect(session.entries(.observation).last?.detail == "\(finding.rawValue),heard,high")
    }

    @Test(arguments: [Finding.chestPain, .otherHeartSigns, .otherConcern, .choking, .limbInjury])
    func aReportInsideTheFlowMovesNothing(finding: Finding) throws {
        var session = try inFlow()
        session.human(.done)
        session.human(.yes)
        let before = session.state
        session.modelFinding(finding)
        #expect(session.state == before)
    }

    /// "He's clutching his chest" at intake stays put, so CPR's default is never taken away.
    @Test(arguments: [Finding.chestPain, .otherHeartSigns, .aspirinUnsafe, .otherConcern, .choking])
    func aRoutingReportAtIntakeDoesNothing(finding: Finding) throws {
        var session = Session(engine: try engine())
        let before = session.state
        session.modelFinding(finding)
        #expect(session.state == before)
        #expect(session.entries(.observation).isEmpty)
        #expect(session.entries(.proposalRejected).last?.detail.hasSuffix("not_applicable") == true)
    }

    @Test func theModelCantSkipToAspirin() throws {
        var session = try inFlow()
        session.human(.done)
        for finding in Finding.allCases {
            report(finding, .high, into: &session)
            #expect(session.state.stateID != "chest_aspirin", "\(finding)")
        }
    }

    // MARK: - Aspirin stops

    @Test func aSureReportStopsAspirinBeforeAndAfterTheDose() throws {
        var check = try inFlow()
        check.human(.done)
        report(.aspirinUnsafe, .medium, into: &check)
        #expect(check.state.stateID == "chest_wait")
        #expect(check.phrases == ["aspirin_stop", "chest_wait_line"])
        #expect(check.entries(.aspirinAdvised).isEmpty)

        var given = try inFlow()
        given.human(.done)
        given.human(.no)
        report(.aspirinUnsafe, .medium, into: &given)
        #expect(given.state.stateID == "chest_wait")
        #expect(given.phrases == ["aspirin_stop", "chest_wait_line"])
        #expect(given.effects.contains(.cutPhrases), "the dose stops mid-line")
    }

    /// "I'm allergic" can come at any point, and silence there would read as nothing being wrong.
    @Test func aSureReportIsAnsweredEverywhereInTheFlow() throws {
        var call = try inFlow()
        report(.aspirinUnsafe, .medium, into: &call)
        #expect(call.state.stateID == "chest_wait", "the question isn't asked at all")
        #expect(call.phrases == ["aspirin_stop", "chest_wait_line"])

        var wait = try inFlow()
        wait.human(.done)
        wait.human(.yes)
        report(.aspirinUnsafe, .high, into: &wait)
        #expect(wait.state.stateID == "chest_wait")
        #expect(wait.phrases == ["aspirin_stop", "chest_wait_line"])

        var scan = try inFlow()
        scan.human(.done)
        scan.human(.yes)
        scan.human(.scan)
        report(.aspirinUnsafe, .high, into: &scan)
        #expect(scan.state.stateID == "chest_scan")
        #expect(scan.phrases == ["aspirin_stop", "aed_look"])
    }

    /// Crossing the tap that gave the dose, a report can still take it back.
    @Test func aStaleReportStillStopsTheDose() throws {
        var session = try inFlow()
        session.human(.done)
        let old = session.proposal(.reportFinding(.aspirinUnsafe, source: .heard, confidence: .high))
        session.human(.no)
        #expect(session.state.stateID == "chest_aspirin")
        session.now += 2
        session.send(.model(old))
        #expect(session.state.stateID == "chest_wait")
        #expect(session.phrases == ["aspirin_stop", "chest_wait_line"])
    }

    // MARK: - One dose

    @Test func aSecondAnswerNeverGivesASecondDose() throws {
        var session = try inFlow()
        session.human(.done)
        session.human(.no)
        #expect(session.phrases == ["aspirin_give"])
        session.human(.notThis)
        session.human(.triageChest)
        session.human(.done)
        session.human(.no)
        #expect(session.state.stateID == "chest_wait")
        #expect(session.phrases == ["chest_wait_line"])
        #expect(session.allPhrases.filter { $0 == "aspirin_give" }.count == 1)
        #expect(session.entries(.aspirinAdvised).count == 1)
    }

    /// Only a tap causes it, so it mustn't read as a timer's doing on the card.
    @Test func theAdviceIsOnRecordAsTheBystanders() throws {
        var session = try inFlow()
        session.human(.done)
        session.human(.no)
        #expect(session.entries(.aspirinAdvised).last?.source == .bystander)
    }

    // MARK: - Not this

    /// The same report straight after would undo the person's choice, and say it all over again.
    @Test(arguments: [Finding.chestPain, .otherHeartSigns])
    func aReportCantChooseAFlowAPersonJustLeft(finding: Finding) throws {
        var session = try inTriage()
        session.modelFinding(finding)
        session.human(.notThis)
        #expect(session.state.stateID == "triage")
        let before = session.state
        session.modelFinding(finding)
        #expect(session.state == before)
        #expect(session.effects.isEmpty)
        #expect(session.entries(.observation).last?.detail == "\(finding.rawValue),heard,high")

        session.human(.triageChest)
        #expect(session.state.stateID == "chest_call", "a person can go back, and that opens it again")
        session.human(.notThis)
        session.human(.triageOther)
        session.modelFinding(.limbInjury)
        #expect(session.state.stateID == "limb_start", "other flows stay open")
    }

    // MARK: - Dispatcher and call

    /// The app said call 911, so the person on that call hasn't failed to answer anything.
    @Test func aStepWaitsForTheDispatcherThenStartsItsClockOver() throws {
        var session = try inFlow()
        session.human(.done)
        session.human(.no)
        #expect(session.state.stateID == "chest_aspirin")
        session.human(.dispatcherOn)
        session.advance(60)
        #expect(session.state.stateID == "chest_aspirin")

        session.human(.dispatcherOff)
        session.advance(14)
        #expect(session.state.stateID == "chest_aspirin", "the whole window is theirs again")
        session.advance(1)
        #expect(session.state.stateID == "chest_wait")
    }

    /// The question doesn't talk over the dispatcher either, and its 10 s start over when they're done.
    @Test func aQuestionWaitsForTheDispatcherThenStartsItsRepeatOver() throws {
        var session = try inFlow()
        session.human(.done)
        session.human(.dispatcherOn)
        session.advance(60)
        #expect(session.state.stateID == "chest_aspirin_check")
        #expect(session.phrases.isEmpty)
        #expect(session.entries(.answer).filter { $0.detail.hasPrefix("aspirin") }.isEmpty)

        session.human(.dispatcherOff)
        session.advance(9)
        #expect(session.phrases.isEmpty, "the whole 10 s is theirs again")
        session.advance(1)
        #expect(session.phrases == ["aspirin_check"])
        #expect(session.state.stateID == "chest_aspirin_check")
    }

    @Test func aReAskWaitsForACallToo() throws {
        var session = try inTriage()
        session.send(.callChanged(active: true))
        session.advance(100)
        #expect(session.phrases.isEmpty)
        session.send(.callChanged(active: false))
        session.advance(29)
        #expect(session.phrases.isEmpty)
        session.advance(1)
        #expect(session.phrases == ["triage_recheck"])
    }

    /// The other side: "no reply goes to CPR" doesn't wait for anything on the arrest path.
    @Test func theArrestPathDoesNotWaitForTheDispatcher() throws {
        var session = Session(engine: try engine())
        session.human(.dispatcherOn)
        session.advance(30)
        #expect(session.state.stateID == "call_911")

        var collapsed = try inFlow()
        collapsed.human(.patientUnresponsive)
        collapsed.human(.dispatcherOn)
        collapsed.advance(30)
        #expect(collapsed.state.stateID == "call_911")
    }

    @Test func aCollapseDoesNotWaitForTheDispatcher() throws {
        var session = try inFlow()
        session.human(.dispatcherOn)
        session.human(.startCpr)
        #expect(session.state.stateID == "compressions")
    }

    // MARK: - A helper

    /// "Find an AED" is for a chest pain or an unknown. Asked mid-question it would also push the question back.
    @Test func theHelperHintIsOnlyWhereAnAEDIsTheNextThought() throws {
        var call = try inFlow()
        call.human(.secondPerson)
        #expect(call.phrases == ["assign_helper"])

        var question = try inFlow()
        question.human(.done)
        question.human(.secondPerson)
        #expect(question.phrases.isEmpty)
        #expect(question.state.resources.contains(.secondPerson))

        var limb = try inTriage()
        limb.human(.triageLimb)
        limb.human(.secondPerson)
        #expect(limb.phrases.isEmpty)
        #expect(limb.state.resources.contains(.secondPerson))
    }

    /// All this edge can do is take aspirin away, so it doesn't wait for a sure report.
    @Test func aDoubtfulReportStopsItToo() throws {
        var session = try inFlow()
        session.human(.done)
        report(.aspirinUnsafe, .low, into: &session)
        #expect(session.state.stateID == "chest_wait")
        #expect(session.phrases == ["aspirin_stop", "chest_wait_line"])
        #expect(session.entries(.aspirinAdvised).isEmpty)
    }

    // MARK: - Once it's ruled out

    /// "I'm allergic to aspirin" said on a step with no edge for it, and one tap later the dose would play.
    @Test(arguments: [Confidence.low, .medium, .high])
    func aRiskReportedBeforeTheCheckStopsTheDose(confidence: Confidence) throws {
        var session = try inTriage()
        report(.aspirinUnsafe, confidence, into: &session)
        #expect(session.state.stateID == "triage", "nothing moves until there's aspirin to stop")
        session.human(.triageChest)
        session.human(.done)
        #expect(session.state.stateID == "chest_aspirin_check")

        session.human(.no)
        #expect(session.state.stateID == "chest_wait")
        #expect(session.phrases == ["aspirin_stop", "chest_wait_line"])
        #expect(!session.allPhrases.contains("aspirin_give"))
        #expect(session.entries(.aspirinAdvised).isEmpty)
        #expect(!session.state.aspirinAdvised)
    }

    @Test func anEarlierNoAspirinStaysNo() throws {
        // Silence no longer rules aspirin out. It only asks again.
        var silent = try inFlow()
        silent.human(.done)
        silent.advance(20)
        #expect(silent.state.stateID == "chest_aspirin_check")
        #expect(silent.phrases == ["aspirin_check"])
        #expect(!silent.state.aspirinRuledOut)

        var reported = try inFlow()
        reported.human(.done)
        report(.aspirinUnsafe, .high, into: &reported)
        #expect(reported.state.aspirinRuledOut)
        reported.human(.notThis)
        reported.human(.triageChest)
        reported.human(.done)
        reported.human(.no)
        #expect(reported.state.stateID == "chest_wait")
        #expect(reported.phrases == ["aspirin_stop", "chest_wait_line"])
        #expect(!reported.allPhrases.contains("aspirin_give"))

        var tapped = try inFlow()
        tapped.human(.done)
        tapped.human(.yes)
        tapped.human(.notThis)
        tapped.human(.triageChest)
        tapped.human(.done)
        tapped.human(.no)
        #expect(!tapped.allPhrases.contains("aspirin_give"))
    }

    /// A rejected report isn't a report. It says nothing about this rescue's patient.
    @Test func aReportThatWasTurnedAwayRulesNothingOut() throws {
        var session = try inFlow()
        let old = session.proposal(.reportFinding(.aspirinUnsafe, source: .heard, confidence: .high))
        session.now += SafetyGate.proposalTTL + 1
        session.send(.model(old))
        #expect(!session.state.aspirinRuledOut)
        session.human(.done)
        session.human(.no)
        #expect(session.state.stateID == "chest_aspirin")
    }

    /// The line could come back through the mic and be reported again, and each one flushes the AI.
    @Test func aRepeatedRiskReportSaysItsLineOncePerCooldown() throws {
        var session = try inFlow()
        session.human(.done)
        session.human(.yes)
        report(.aspirinUnsafe, .high, into: &session)
        #expect(session.phrases == ["aspirin_stop", "chest_wait_line"])
        let version = session.state.version

        for _ in 0..<4 {
            session.now += 4.5
            report(.aspirinUnsafe, .high, into: &session)
            #expect(session.phrases.isEmpty)
            #expect(session.effects.isEmpty)
            #expect(session.state.version == version)
        }
        #expect(session.entries(.observation).count == 5, "each one still goes on the record")

        session.now += SafetyGate.sayCooldown - 18
        report(.aspirinUnsafe, .high, into: &session)
        #expect(session.phrases == ["aspirin_stop", "chest_wait_line"], "and it can be said again once the cooldown is past")
    }

    /// Only a line already said holds it back, so the first report on a step still gets its answer.
    @Test func aFirstRiskReportOnAStepIsAnsweredAtOnce() throws {
        var session = try inFlow()
        session.human(.done)
        session.human(.yes)
        session.human(.scan)
        session.now += 1
        report(.aspirinUnsafe, .high, into: &session)
        #expect(session.phrases == ["aspirin_stop", "aed_look"])
    }

    // MARK: - The question before CPR

    /// Two reports, however sure, can't take a talking patient to compressions with nobody tapping.
    @Test(arguments: [
        (Finding.abnormalBreathing, Finding.abnormalBreathing),
        (.notBreathing, .abnormalBreathing),
        (.unresponsive, .notBreathing),
    ])
    func aSecondReportWaitsOnTheQuestion(first: Finding, second: Finding) throws {
        var session = try inFlow()
        session.human(.done)
        session.human(.yes)
        report(first, .low, into: &session)
        #expect(session.state.stateID == "intake_breathing")
        #expect(session.state.breathingAskedAwake)

        session.now += 1
        let before = session.state
        report(second, .high, into: &session)
        #expect(session.state == before)
        #expect(session.effects.isEmpty)
        #expect(session.entries(.observation).last?.detail == "\(second.rawValue),heard,high")

        session.advance(9)
        #expect(session.phrases == ["ask_breathing"], "the question repeats at 10 s")
        session.advance(20)
        #expect(session.state.stateID == "call_911", "no reply still gets there, on the question's own clock")
        #expect(!session.state.breathingAskedAwake)
    }

    @Test func aTapStillAnswersTheQuestionAtOnce() throws {
        var session = try inFlow()
        session.modelFinding(.abnormalBreathing)
        session.human(.no)
        #expect(session.state.stateID == "call_911")
    }

    /// "Yes, breathing" can't be the thing that lets the next report through. Nobody tapped that they aren't.
    @Test(arguments: [Finding.abnormalBreathing, .notBreathing, .unresponsive])
    func aYesKeepsTheQuestionStandingThroughTheWatch(finding: Finding) throws {
        var session = try inFlow()
        report(.unresponsive, .low, into: &session)
        session.human(.yes)
        #expect(session.state.stateID == "watch_breathing")
        #expect(session.state.breathingAskedAwake)

        let before = session.state
        session.now += 1
        report(finding, .high, into: &session)
        #expect(session.state == before)
        #expect(session.effects.isEmpty)
        #expect(session.entries(.observation).last?.detail == "\(finding.rawValue),heard,high")
    }

    @Test func theWatchKeepsItsOwnClockAndTheLatchEndsWithIt() throws {
        var session = try inFlow()
        session.human(.patientUnresponsive)
        session.human(.yes)
        session.advance(10)
        #expect(session.state.stateID == "call_911", "no breaths marked still gets there")
        #expect(!session.state.breathingAskedAwake)
        for _ in 0..<15 { session.advance(1) }
        #expect(session.state.stateID == "call_911", "the setup steps wait for a tap")
        session.human(.called)
        session.human(.done)
        session.human(.done)
        #expect(session.state.stateID == "compressions")
        #expect(!session.state.breathingAskedAwake)
    }

    @Test func aTapStillLeavesTheWatchAtOnce() throws {
        var session = try inFlow()
        session.human(.patientUnresponsive)
        session.human(.yes)
        session.human(.startCpr)
        #expect(session.state.stateID == "compressions")
    }

    /// The route that never went awake takes the report as it always has.
    @Test func aWatchReachedFromIntakeStillTakesAReport() throws {
        var session = Session(engine: try engine())
        session.human(.no)
        #expect(session.state.stateID == "intake_breathing")
        session.human(.yes)
        #expect(session.state.stateID == "watch_breathing")
        #expect(!session.state.breathingAskedAwake)
        session.modelFinding(.abnormalBreathing)
        #expect(session.state.stateID == "call_911")
    }

    /// The other side: the arrest path takes the second report at once, as it always has.
    @Test func aReportFromIntakeStillMovesThroughTheQuestion() throws {
        var session = Session(engine: try engine())
        session.modelFinding(.unresponsive)
        #expect(session.state.stateID == "intake_breathing")
        #expect(!session.state.breathingAskedAwake)
        session.modelFinding(.abnormalBreathing)
        #expect(session.state.stateID == "call_911")
    }

    // MARK: - Arrest prompts stay on the arrest path

    @Test(arguments: [Finding.responsive, .breathingNormally, .patientMoving, .emsArrived])
    func aRejectedLoweringReportDoesNotReAskAnAwakeQuestion(finding: Finding) throws {
        var session = try inFlow()
        session.human(.done)
        #expect(session.state.stateID == "chest_aspirin_check")
        session.send(.phrasePlayed("aspirin_check"))

        session.modelFinding(finding)
        #expect(session.state.stateID == "chest_aspirin_check")
        #expect(session.phrases.isEmpty, "\(session.phrases)")
        #expect(session.entries(.proposalRejected).last?.detail.hasSuffix("cannot_lower_urgency") == true)
    }

    /// The other side: this bundle changed nothing on the questions that asked before.
    @Test func aRejectedLoweringReportStillReAsksAtIntake() throws {
        var session = Session(engine: try engine())
        session.send(.phrasePlayed("ask_responsive"))
        session.modelFinding(.breathingNormally)
        #expect(session.phrases == ["ask_responsive"])

        var breathing = Session(engine: try engine())
        breathing.human(.no)
        breathing.modelFinding(.breathingNormally)
        #expect(breathing.phrases == ["confirm_by_tap"])
    }

    // MARK: - A flagged line around a closed voice

    /// The line that routed here may be what's flagged, and the voice closed only just now.
    @Test func aFlaggedLineIsStillCorrectedRightAfterRoutingIntoAClosedStep() throws {
        var session = try inTriage()
        session.modelFinding(.chestPain)
        #expect(!session.engine.policy(for: session.state, at: session.now).modelSpeechOpen)
        session.now += SafetyGate.heardGrace - 1
        session.send(.sentinelFlag(SentinelFlag(category: .diagnosis, excerpt: "it's definitely a heart attack")))
        #expect(session.phrases == ["correct_diagnosis"])
    }

    @Test func aFlaggedLineLongAfterTheVoiceClosedWasNeverHeard() throws {
        var session = try inTriage()
        session.modelFinding(.chestPain)
        session.now += SafetyGate.heardGrace
        session.send(.sentinelFlag(SentinelFlag(category: .diagnosis, excerpt: "x")))
        #expect(session.phrases.isEmpty)
        #expect(session.effects.contains(.flushModelAudio))
    }

    /// Core's closed states with nothing to say are as quiet as they were.
    @Test func aStaticCardStaysQuietForAFlag() throws {
        var card = try inTriage()
        card.human(.patientUnresponsive)
        card.human(.yes)
        card.human(.patientAwake)
        #expect(card.state.stateID == "responsive_patient")
        card.send(.sentinelFlag(SentinelFlag(category: .pulseCheck, excerpt: "x")))
        #expect(card.phrases.isEmpty)

        var special = try inTriage()
        special.human(.notAdult)
        #expect(special.state.stateID == "special_patient")
        special.send(.sentinelFlag(SentinelFlag(category: .pulseCheck, excerpt: "x")))
        #expect(special.phrases.isEmpty)
    }

    // MARK: - After pads or CPR

    @Test func triageStaysClosedAfterCPR() throws {
        var session = Session(engine: try engine())
        session.goToAnalysis()
        session.human(.patientMoving)
        session.human(.patientAwake)
        #expect(session.state.stateID == "responsive_patient")
        session.human(.triageOpen)
        #expect(session.state.stateID == "responsive_patient")
        #expect(session.entries(.flowEntered).isEmpty)
        #expect(!session.allPhrases.contains("triage_ask"))
    }
}
