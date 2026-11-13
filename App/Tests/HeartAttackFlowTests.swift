import Foundation
@testable import HealthAISim
import RescueCore
import Testing

/// The merged bundle through the real coordinator, with no key, no model, and no network. The arrest
/// suites stay on `shippedBundle()`, which is core only.
@MainActor
@Suite struct HeartAttackFlowTests {
    private func begun() throws -> Fixture {
        let fixture = try Fixture(bundle: try mergedBundle())
        fixture.coordinator.beginRescue()
        return fixture
    }

    private func text(_ fixture: Fixture, _ id: String) -> String {
        fixture.coordinator.engine.bundle.text(forPhrase: id) ?? ""
    }

    private func expectOffline(_ fixture: Fixture, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(fixture.coordinator.linkLabel == "Offline protocol", sourceLocation: sourceLocation)
        #expect(fixture.mock.requests.isEmpty, sourceLocation: sourceLocation)
    }

    private func explanation(_ fixture: Fixture) -> FlowExplanation? {
        FlowExplanation.build(from: fixture.coordinator.log.entries, bundle: fixture.coordinator.engine.bundle)
    }

    // MARK: - By taps

    @Test func theWholeFlowByTaps() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.perform(.yes)
        #expect(coordinator.state.stateID == "triage")
        #expect(coordinator.instruction == text(fixture, "triage_ask"))

        coordinator.perform(.triageChest)
        #expect(coordinator.state.stateID == "chest_call")
        #expect(explanation(fixture)?.chooser == .person)
        coordinator.perform(.done)
        #expect(coordinator.state.stateID == "chest_aspirin_check")
        #expect(coordinator.instruction == text(fixture, "aspirin_check"))
        #expect(coordinator.controls.filter { $0.role == .answer }.map(\.action) == [.yes, .no, .unsure])

        coordinator.perform(.no)
        #expect(coordinator.state.stateID == "chest_aspirin")
        #expect(coordinator.instruction == text(fixture, "aspirin_give"))

        coordinator.perform(.done)
        #expect(coordinator.state.stateID == "chest_wait")
        coordinator.perform(.scan)
        #expect(coordinator.state.stateID == "chest_scan")
        #expect(coordinator.overlayTarget == .aedDevice)
        coordinator.perform(.done)
        #expect(coordinator.state.stateID == "chest_wait")
        #expect(coordinator.overlayTarget == nil)

        #expect(fixture.audio.played == [
            "ask_responsive", "triage_ask", "chest_possible", "call_911", "chest_sit",
            "aspirin_check", "aspirin_give", "chest_wait_line", "aed_look", "chest_wait_line",
        ])
        #expect(fixture.audio.metronome.isEmpty, "nothing here may start the beat")
        expectOffline(fixture)
    }

    @Test func aCollapseFromTheWaitReachesCompressionsAndKeepsTheConcern() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.perform(.yes)
        coordinator.perform(.triageChest)
        coordinator.perform(.done)
        coordinator.perform(.yes)
        fixture.audio.clearCalls()

        coordinator.perform(.patientUnresponsive)
        #expect(coordinator.state.stateID == "intake_breathing")
        #expect(fixture.audio.calls.contains(.cut), "whatever was playing stops at once")
        #expect(explanation(fixture) == nil, "the why panel is about a flow they've left")

        coordinator.perform(.no)
        coordinator.perform(.called)
        coordinator.perform(.done)
        coordinator.perform(.done)
        #expect(coordinator.state.stateID == "compressions")
        #expect(fixture.audio.metronome == [true])

        let card = coordinator.handoffCard
        #expect(card.items.first { $0.label == "Concern" }?.value == "Possible heart attack. Not a diagnosis.")
        #expect(card.items.first { $0.label == "Coaching started" }?.value != "not recorded")
        #expect(coordinator.callerScript.situation.contains("possible heart attack"))
        expectOffline(fixture)
    }

    // MARK: - By timeouts

    @Test func theWholeFlowByTimeoutsNeverGivesAspirinOrStartsCPR() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.perform(.yes)
        coordinator.perform(.triageChest)
        fixture.audio.clearCalls()

        fixture.run(seconds: 15.2)
        #expect(coordinator.state.stateID == "chest_aspirin_check")
        fixture.run(seconds: 20.2)
        #expect(coordinator.state.stateID == "chest_wait")
        #expect(fixture.logDetails(.answer).last == "aspirin_risk_reported=no_reply")
        #expect(fixture.audio.played == ["aspirin_check", "aspirin_skip", "chest_wait_line"])

        fixture.run(seconds: 95)
        #expect(coordinator.state.stateID == "chest_wait", "no reply never leaves for CPR here")
        #expect(fixture.audio.played.filter { $0 == "chest_wait_line" }.count == 4, "re-asked every 30 s")
        #expect(!fixture.audio.played.contains("aspirin_give"))
        #expect(fixture.logDetails(.aspirinAdvised).isEmpty)
        #expect(fixture.audio.metronome.isEmpty)
        expectOffline(fixture)
    }

    @Test func theAspirinStepAndTheScanEndOnTheirOwn() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.perform(.yes)
        coordinator.perform(.triageChest)
        coordinator.perform(.done)
        coordinator.perform(.no)
        fixture.run(seconds: 15.2)
        #expect(coordinator.state.stateID == "chest_wait")

        coordinator.perform(.scan)
        #expect(coordinator.state.stateID == "chest_scan")
        fixture.run(seconds: 20.2)
        #expect(coordinator.state.stateID == "chest_wait")
        #expect(coordinator.overlayTarget == nil)
        expectOffline(fixture)
    }

    @Test(arguments: ["triage", "general_talk", "choking_talk", "chest_call", "chest_aspirin_check", "chest_aspirin", "chest_wait", "chest_scan"])
    func aTappedCollapseFromAnyAwakeStateIsCompressingWithin30Seconds(id: String) throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.force(stateID: id)
        #expect(coordinator.state.stateID == id)

        coordinator.perform(.patientUnresponsive)
        #expect(coordinator.state.stateID == "intake_breathing")
        fixture.run(seconds: 25.6)
        #expect(coordinator.state.stateID == "compressions")
        #expect(coordinator.showsPulse)
    }

    @Test func noTouchFromLaunchIsStillTheArrestPath() throws {
        let fixture = try begun()
        fixture.run(seconds: 26)
        #expect(fixture.coordinator.state.stateID == "compressions")
        #expect(fixture.audio.played == ["ask_responsive", "call_911", "roll_flat", "hands_center", "start_compressions"])
        #expect(fixture.audio.metronome == [true])
    }

    // MARK: - The screen

    /// Audio can be down, so each phrase has to reach the screen as well as the speaker.
    @Test func everyEntryPhrasePlaysAndTheScreenShowsThemAll() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.perform(.yes)
        fixture.audio.clearCalls()

        coordinator.perform(.triageChest)
        #expect(fixture.audio.lane == ["chest_possible", "call_911", "chest_sit"])
        #expect(coordinator.instruction == text(fixture, "chest_possible"))
        #expect(coordinator.stepDetail == "\(text(fixture, "call_911")) \(text(fixture, "chest_sit"))")
        #expect(coordinator.prompt == nil, "shown once, not twice")
    }

    /// The first entry phrase is what `instruction` shows, so it isn't shown twice.
    @Test func aOnePhraseStepShowsItOnce() throws {
        let fixture = try begun()
        fixture.coordinator.perform(.yes)
        #expect(fixture.coordinator.instruction == text(fixture, "triage_ask"))
        #expect(fixture.coordinator.prompt == nil)
    }

    @Test func anEdgesPhraseShowsAboveTheStep() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.perform(.yes)
        coordinator.perform(.triageChest)
        coordinator.perform(.done)
        fixture.run(seconds: 8.2)
        #expect(coordinator.prompt == nil)

        coordinator.perform(.yes)
        #expect(coordinator.prompt?.text == text(fixture, "aspirin_skip"))
        #expect(coordinator.instruction == text(fixture, "chest_wait_line"))
    }

    /// A step's own line is already on screen, so its re-ask adds nothing there.
    @Test func aReAskDoesNotPileOntoTheScreen() throws {
        let fixture = try begun()
        fixture.coordinator.perform(.yes)
        fixture.coordinator.perform(.triageOther)
        fixture.run(seconds: 30.2)
        #expect(fixture.audio.played.filter { $0 == "general_intro" }.count == 2)
        #expect(fixture.coordinator.prompt == nil)
    }

    /// The static card has a call prompt and a re-check, so a mis-tapped Yes doesn't get less here.
    @Test func triageRepeatsTheCallPromptAndTheReCheckAndShowsThem() throws {
        let fixture = try begun()
        fixture.coordinator.perform(.yes)
        fixture.audio.clearCalls()
        fixture.run(seconds: 30.2)
        #expect(fixture.audio.played == ["triage_recheck"])
        #expect(fixture.coordinator.prompt?.text == text(fixture, "triage_recheck"))
        #expect(fixture.coordinator.instruction == text(fixture, "triage_ask"))
    }

    // MARK: - What the lane really keeps

    /// Done on the first line can't have answered a call prompt nobody has heard yet.
    @Test func doneTappedEarlyStillSaysTheCallPromptAndTheStepsOwnLine() throws {
        let fixture = try begun()
        fixture.coordinator.perform(.yes)
        fixture.audio.clearCalls()
        fixture.coordinator.perform(.triageChest)
        fixture.coordinator.perform(.done)
        #expect(fixture.audio.lane == ["chest_possible", "call_911", "chest_sit", "aspirin_check"])
    }

    @Test func calledAnswersThePromptAndNothingElse() throws {
        let fixture = try begun()
        fixture.coordinator.perform(.yes)
        fixture.audio.clearCalls()
        fixture.coordinator.perform(.triageChest)
        fixture.coordinator.perform(.called)
        #expect(fixture.audio.lane == ["chest_possible", "chest_sit", "aspirin_check"])
    }

    /// Timers flush nothing, so with no touch every line gets said before the next step's.
    @Test func noTouchSaysEverythingInOrder() throws {
        let fixture = try begun()
        fixture.coordinator.perform(.yes)
        fixture.audio.clearCalls()
        fixture.coordinator.perform(.triageChest)
        fixture.run(seconds: 15.2)
        #expect(fixture.audio.lane == ["chest_possible", "call_911", "chest_sit", "aspirin_check"])
    }

    @Test func aCollapseCutsTheLane() throws {
        let fixture = try begun()
        fixture.coordinator.perform(.yes)
        fixture.audio.clearCalls()
        fixture.coordinator.perform(.triageChest)
        fixture.coordinator.perform(.patientUnresponsive)
        #expect(fixture.audio.lane == ["ask_breathing"])
    }

    // MARK: - A tap aimed at the last step

    /// The step moved on by its timer as someone reached for Done, whose spot is now an answer.
    @Test func anAnswerWaitsForTheQuestionToLand() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.perform(.yes)
        coordinator.perform(.triageChest)
        fixture.run(seconds: 15.2)
        #expect(coordinator.state.stateID == "chest_aspirin_check")

        coordinator.performStep(.no)
        #expect(coordinator.state.stateID == "chest_aspirin_check", "no dose on a tap meant for the last step")
        #expect(fixture.logDetails(.aspirinAdvised).isEmpty)

        fixture.run(seconds: 1.0)
        coordinator.performStep(.no)
        #expect(coordinator.state.stateID == "chest_aspirin_check")

        fixture.run(seconds: 1.2)
        coordinator.performStep(.no)
        #expect(coordinator.state.stateID == "chest_aspirin")
    }

    /// The same step on the limb flow, where a stale No would skip the danger branch.
    @Test func theLimbQuestionWaitsToo() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.perform(.yes)
        coordinator.perform(.triageLimb)
        coordinator.perform(.done)
        fixture.run(seconds: 1.0)
        coordinator.performStep(.no)
        #expect(coordinator.state.stateID == "limb_flags")
        #expect(fixture.logDetails(.answer).filter { $0.hasPrefix("danger_signs") }.isEmpty)
    }

    /// The way out never waits, wherever it lands.
    @Test func theWayOutNeverWaits() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.perform(.yes)
        coordinator.perform(.triageChest)
        coordinator.perform(.done)
        #expect(coordinator.stepIsSettling)
        coordinator.perform(.startCpr)
        #expect(coordinator.state.stateID == "compressions")
    }

    // MARK: - Behind the sheet

    /// "Call 911" is what opened this sheet, and an unanswered question behind it isn't anyone's silence.
    @Test func aQuestionWaitsBehindTheDispatcherSheet() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.perform(.yes)
        coordinator.perform(.triageChest)
        coordinator.perform(.done)
        coordinator.setDispatcher(open: true)
        fixture.audio.clearCalls()
        fixture.run(seconds: 40)
        #expect(coordinator.state.stateID == "chest_aspirin_check")
        #expect(coordinator.secondsUntilTimeout == nil, "nothing is counting down")
        #expect(fixture.audio.played.isEmpty)
        #expect(!fixture.logDetails(.answer).contains { $0.hasPrefix("aspirin") })

        coordinator.setDispatcher(open: false)
        #expect(coordinator.secondsUntilTimeout == 20)
        fixture.run(seconds: 20.2)
        #expect(coordinator.state.stateID == "chest_wait")
    }

    // MARK: - The voice

    /// The app runs this bundle, and each mode has its own session, so the modules' open states are open.
    @Test func awakeVoiceOpensWhereTheModulesSayAndNowhereElse() throws {
        let bundle = try mergedBundle()
        let open = Set(bundle.definition.speechGate.openStates)
        #expect(open.isSuperset(of: ["triage", "general_talk", "choking_talk", "chest_wait", "limb_wait", "limb_danger"]))
        let fixture = try Fixture(bundle: bundle)
        fixture.coordinator.beginRescue()
        for state in bundle.definition.states where state.kind.isAwake {
            fixture.coordinator.force(stateID: state.id)
            #expect(fixture.coordinator.state.stateID == state.id)
            #expect(fixture.audio.lastPolicy?.modelSpeechOpen == open.contains(state.id), "\(state.id)")
        }
    }

    @Test func aReportThatMovedNothingShowsOnTheStep() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.perform(.yes)
        coordinator.perform(.triageLimb)
        #expect(coordinator.observationNote == nil)
        coordinator.dispatch(.model(ModelProposal(
            action: .reportFinding(.chestPain, source: .heard, confidence: .high),
            stateVersion: coordinator.state.version,
            issuedAt: fixture.clock.now
        )))
        #expect(coordinator.state.stateID == "limb_start")
        #expect(coordinator.observationNote == "AI heard: chest pain (high). Nothing changed.")
        coordinator.perform(.done)
        #expect(coordinator.observationNote == nil)
    }

    // MARK: - Controls and stage control

    @Test func everyControlDoesWhatTheBundleSays() throws {
        let bundle = try mergedBundle()
        for state in bundle.definition.states where state.kind.isAwake {
            let controls = try {
                let fixture = try begun()
                fixture.coordinator.force(stateID: state.id)
                return fixture.coordinator.controls
            }()
            // An edge back to the same step stays in the graph, and has nothing to offer on screen.
            for transition in state.transitions where transition.on.hasPrefix("human.") && transition.to != state.id {
                let name = String(transition.on.dropFirst("human.".count))
                let action = try #require(HumanAction(rawValue: name), "\(state.id): \(transition.on)")
                #expect(controls.contains { $0.action == action }, "\(state.id) doesn't offer \(name)")

                let driven = try begun()
                driven.coordinator.force(stateID: state.id)
                driven.coordinator.perform(action)
                #expect(driven.coordinator.state.stateID == transition.to, "\(state.id) + \(name)")
            }
            #expect(controls.contains { $0.action == .startCpr }, "\(state.id)")
            #expect(controls.contains { $0.action == .patientUnresponsive }, "\(state.id)")
            #expect(controls.first { $0.action == .startCpr }?.role == .primary, "\(state.id)")
        }
    }

    @Test func everyStateIsReachableFromEveryState() throws {
        let bundle = try mergedBundle()
        let engine = ProtocolEngine(bundle: bundle)
        for from in bundle.definition.states {
            for to in bundle.definition.states where to.id != from.id {
                #expect(OperatorForce.path(engine: engine, from: from.id, to: to.id) != nil, "\(from.id) to \(to.id)")
            }
        }
    }

    /// The real walk, which only the app can run. It can't leave a person's choice or an AI's on record.
    @Test func aForcedWalkIntoTheFlowIsNobodysChoice() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.force(stateID: "chest_wait")
        #expect(coordinator.state.stateID == "chest_wait")

        let entered = coordinator.log.entries.filter { $0.kind == .flowEntered }
        #expect(entered.map(\.detail) == ["possible_heart_attack"])
        #expect(entered.first?.source == .system)

        let built = try #require(explanation(fixture))
        #expect(built.chooser == .neither)
        #expect(built.lines.isEmpty)
        #expect(built.headline == "Possible heart attack. Not a diagnosis.")
        #expect(coordinator.handoffCard.items.first { $0.label == "Concern" }?.source == .system)

        coordinator.force(stateID: "triage")
        #expect(explanation(fixture) == nil)
        coordinator.force(stateID: "chest_scan")
        #expect(explanation(fixture)?.chooser == .neither)
        coordinator.force(stateID: "compressions")
        #expect(explanation(fixture) == nil)
    }

    /// The engine would send a tap from here to the card, so stage control doesn't get to skip that.
    @Test(arguments: ["triage", "chest_call", "chest_aspirin", "chest_wait", "limb_start", "general_talk"])
    func aLockedPatientCantBeForcedIntoAnAwakeState(id: String) throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.perform(.startCpr)
        coordinator.perform(.patientMoving)
        coordinator.perform(.patientAwake)
        #expect(coordinator.state.stateID == "responsive_patient")
        coordinator.force(stateID: id)
        #expect(coordinator.state.stateID == "responsive_patient")
        #expect(!coordinator.operatorUsed)
    }

    /// The walk from the card to the responsive card goes through compressions, which nobody did.
    @Test func aWalkThroughCPRLeavesNoCPROnRecord() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.force(stateID: "handoff")
        #expect(!coordinator.state.cprStarted)
        coordinator.force(stateID: "triage")
        #expect(coordinator.state.stateID == "triage")
        #expect(!coordinator.state.cprStarted)
        coordinator.perform(.notAdult)
        coordinator.force(stateID: "chest_wait")
        #expect(coordinator.state.stateID == "chest_wait", "still not locked out of the flows")

        coordinator.force(stateID: "compressions")
        #expect(coordinator.state.cprStarted, "this one is CPR")
    }

    /// Only the destination speaks. "No aspirin" answers a question nobody was asked.
    @Test func aForcedStepSaysOnlyItsOwnLines() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.perform(.yes)
        coordinator.perform(.triageChest)
        coordinator.perform(.done)
        fixture.audio.clearCalls()
        coordinator.force(stateID: "chest_wait")
        #expect(coordinator.state.stateID == "chest_wait")
        #expect(fixture.audio.played == ["chest_wait_line"])
        #expect(coordinator.prompt == nil)
    }

    /// A forced dose isn't a person's tap, and doesn't read as one. It does count as the one dose.
    @Test func aForcedDoseIsNobodysTapAndStillCounts() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.force(stateID: "chest_aspirin")
        #expect(coordinator.state.stateID == "chest_aspirin")
        #expect(coordinator.log.entries.last { $0.kind == .aspirinAdvised }?.source == .system)
        #expect(coordinator.state.aspirinAdvised)
        #expect(!fixture.logDetails(.answer).contains { $0.hasPrefix("aspirin") })

        // Invariant 15: the dose plays once in a rescue, so stage control can't play it again.
        coordinator.force(stateID: "chest_wait")
        coordinator.force(stateID: "chest_aspirin")
        #expect(coordinator.state.stateID == "chest_wait")
        #expect(coordinator.handoffCard.items.filter { $0.label.hasPrefix("Aspirin advised") }.count == 1)
    }

    /// Nor once someone has reported an aspirin risk.
    @Test func aForcedDoseIsRefusedOnceAspirinIsRuledOut() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.perform(.yes)
        coordinator.perform(.triageChest)
        coordinator.perform(.done)
        coordinator.perform(.yes)
        #expect(coordinator.state.aspirinRuledOut)
        let stateID = coordinator.state.stateID
        coordinator.force(stateID: "chest_aspirin")
        #expect(coordinator.state.stateID == stateID)
        #expect(!fixture.audio.played.contains("aspirin_give"))
        #expect(coordinator.log.entries.allSatisfy { $0.kind != .aspirinAdvised })
    }

    /// The walk to the wait crosses Yes at the aspirin check, which is nobody's answer, so it rules
    /// nothing out, tells the AI nothing of the kind, and leaves a staged dose possible.
    @Test func aForcedWaitRulesNoAspirinOut() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        let walked = try #require(OperatorForce.walk(engine: coordinator.engine, from: coordinator.state, to: "chest_wait", at: fixture.clock.now))
        let briefs = walked.effects.compactMap { if case let .sendStateBrief(brief) = $0 { brief } else { nil } }
        #expect(!briefs.isEmpty)
        #expect(briefs.allSatisfy { $0.aspirin == .notAsked })

        coordinator.force(stateID: "chest_wait")
        #expect(!coordinator.state.aspirinRuledOut)
        #expect(!OperatorForce.refuses(engine: coordinator.engine, state: coordinator.state, target: "chest_aspirin"))
        coordinator.force(stateID: "chest_aspirin")
        #expect(coordinator.state.stateID == "chest_aspirin")
        #expect(fixture.audio.played.contains("aspirin_give"))
        #expect(OperatorForce.refuses(engine: coordinator.engine, state: coordinator.state, target: "chest_aspirin"), "and greyed out once it has played")
    }

    /// Going through Not this to get across is the walk's doing, not a person's.
    @Test func aForcedWalkDeclinesNoFlow() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.force(stateID: "chest_wait")
        coordinator.force(stateID: "limb_start")
        #expect(coordinator.state.stateID == "limb_start")
        #expect(coordinator.state.declinedFlows.isEmpty)
    }

    /// "No aspirin" means nothing once they've backed out of the flow it was about.
    @Test func aPassingLineDoesNotFollowAcrossFlows() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.perform(.yes)
        coordinator.perform(.triageChest)
        coordinator.perform(.done)
        coordinator.perform(.yes)
        #expect(coordinator.prompt?.text == text(fixture, "aspirin_skip"))
        coordinator.perform(.notThis)
        #expect(coordinator.prompt == nil)
    }

    @Test func aForcedStepInsideAChosenFlowKeepsWhoChoseIt() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.perform(.yes)
        coordinator.perform(.triageChest)
        coordinator.force(stateID: "chest_scan")
        #expect(explanation(fixture)?.chooser == .person)
    }

    /// A rescue restarted from the top starts over, with nothing left on the panel or the card.
    @Test func aRestartForgetsTheConcern() throws {
        let fixture = try begun()
        fixture.coordinator.perform(.yes)
        fixture.coordinator.perform(.triageChest)
        fixture.coordinator.restartRescue()
        #expect(explanation(fixture) == nil)
        #expect(fixture.coordinator.handoffCard.items.first { $0.label == "Concern" } == nil)
        #expect(fixture.coordinator.state.stateID == "intake_responsive")
    }

    /// The dose, or the chest step's three lines, mustn't play on ahead of "Are they responding?".
    @Test func aRestartCutsTheAwakeLinesStillToPlay() throws {
        let fixture = try begun()
        fixture.coordinator.perform(.yes)
        fixture.coordinator.perform(.triageChest)
        #expect(fixture.audio.lane.contains("chest_sit"))
        fixture.coordinator.restartRescue()
        #expect(fixture.audio.lane == fixture.coordinator.definition?.entryPhrases)
    }

    /// Nothing changes for a rescue that never left the arrest path.
    @Test func anArrestOnlyRestartCutsNothing() throws {
        let fixture = try begun()
        fixture.coordinator.perform(.no)
        fixture.audio.clearCalls()
        fixture.coordinator.restartRescue()
        #expect(!fixture.audio.calls.contains(.cut))
    }
}
