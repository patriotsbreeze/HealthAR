import Foundation
@testable import HealthAISim
import RescueCore
import Testing

/// The merged bundle through the real coordinator, with no key, no model, and no network.
@MainActor
@Suite struct BrokenBoneFlowTests {
    private func inFlow() throws -> Fixture {
        let fixture = try Fixture(bundle: try mergedBundle())
        fixture.coordinator.beginRescue()
        fixture.coordinator.perform(.yes)
        fixture.coordinator.perform(.triageLimb)
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
        let fixture = try inFlow()
        let coordinator = fixture.coordinator
        #expect(coordinator.state.stateID == "limb_start")
        #expect(coordinator.instruction == text(fixture, "limb_possible"))
        #expect(explanation(fixture)?.chooser == .person)
        #expect(explanation(fixture)?.headline == "Possible broken bone. Not a diagnosis.")

        coordinator.perform(.done)
        #expect(coordinator.state.stateID == "limb_flags")
        #expect(coordinator.instruction == text(fixture, "limb_danger_ask"))
        #expect(coordinator.controls.filter { $0.role == .answer }.map(\.action) == [.yes, .no, .unsure])

        coordinator.perform(.no)
        #expect(coordinator.state.stateID == "limb_splint")
        #expect(coordinator.instruction == text(fixture, "limb_wound"))
        #expect(coordinator.stepDetail == text(fixture, "limb_support"))
        #expect(fixture.logDetails(.answer).last == "danger_signs=no")

        coordinator.perform(.done)
        #expect(coordinator.state.stateID == "limb_wait")
        #expect(coordinator.instruction == text(fixture, "limb_seek_care"))

        #expect(fixture.audio.played == [
            "ask_responsive", "triage_ask", "limb_possible", "limb_danger_ask", "limb_wound", "limb_support", "limb_seek_care",
        ])
        #expect(fixture.logDetails(.callPrompted).isEmpty)
        #expect(fixture.audio.metronome.isEmpty, "nothing here may start the beat")
        #expect(coordinator.overlayTarget == .injurySite)
        expectOffline(fixture)
    }

    @Test(arguments: [HumanAction.yes, .unsure])
    func theDangerBranchByTaps(action: HumanAction) throws {
        let fixture = try inFlow()
        let coordinator = fixture.coordinator
        coordinator.perform(.done)
        fixture.audio.clearCalls()

        coordinator.perform(action)
        #expect(coordinator.state.stateID == "limb_danger")
        #expect(fixture.audio.played == ["call_911", "limb_danger_care", "limb_tourniquet"])
        #expect(coordinator.instruction == text(fixture, "call_911"))
        #expect(coordinator.stepDetail == "\(text(fixture, "limb_danger_care")) \(text(fixture, "limb_tourniquet"))")
        #expect(fixture.logDetails(.answer).last == "danger_signs=\(action.rawValue)")
        #expect(fixture.logDetails(.callPrompted).count == 1)

        #expect(coordinator.handoffCard.items.first { $0.label == "Concern" }?.value == "Possible broken bone. Not a diagnosis.")
        #expect(coordinator.callerScript.situation.contains("possible broken bone"))
        #expect(fixture.audio.metronome.isEmpty)
        expectOffline(fixture)
    }

    // MARK: - By timeouts

    /// No step moves on by itself: each says its line again every 10 s, and an unsure answer takes the
    /// danger branch.
    @Test func withNoReplyEachStepWaitsAndUnsureTakesTheDangerBranchAndNeverStartsCPR() throws {
        let fixture = try inFlow()
        let coordinator = fixture.coordinator
        fixture.audio.clearCalls()

        fixture.run(seconds: 30.2)
        #expect(coordinator.state.stateID == "limb_start")
        #expect(fixture.audio.played == ["limb_possible", "limb_possible", "limb_possible"])
        coordinator.perform(.done)
        #expect(coordinator.state.stateID == "limb_flags")
        fixture.audio.clearCalls()

        fixture.run(seconds: 30.2)
        #expect(coordinator.state.stateID == "limb_flags", "a danger question waits for an answer")
        #expect(fixture.audio.played.filter { $0 == "limb_danger_ask" }.count == 3)
        #expect(fixture.logDetails(.callPrompted).isEmpty)
        fixture.audio.clearCalls()

        fixture.run(seconds: 1.2)
        coordinator.performStep(.unsure)
        #expect(coordinator.state.stateID == "limb_danger")
        #expect(fixture.logDetails(.answer).last == "danger_signs=unsure")
        #expect(fixture.logDetails(.callPrompted).count == 1)
        #expect(fixture.audio.played == ["call_911", "limb_danger_care", "limb_tourniquet"])

        fixture.run(seconds: 95)
        #expect(coordinator.state.stateID == "limb_danger", "no reply never leaves for CPR here")
        #expect(fixture.audio.played.filter { $0 == "limb_danger_care" }.count == 4, "re-asked every 30 s")
        #expect(!fixture.audio.played.contains("limb_wound"))
        #expect(fixture.audio.metronome.isEmpty)
        expectOffline(fixture)
    }

    @Test func theSplintStepWaitsForDoneAndTheWaitReAsks() throws {
        let fixture = try inFlow()
        let coordinator = fixture.coordinator
        coordinator.perform(.done)
        coordinator.perform(.no)
        fixture.audio.clearCalls()

        fixture.run(seconds: 20.2)
        #expect(coordinator.state.stateID == "limb_splint")
        #expect(fixture.audio.played == ["limb_support", "limb_support"])
        fixture.audio.clearCalls()
        coordinator.perform(.done)
        #expect(coordinator.state.stateID == "limb_wait")
        #expect(fixture.audio.played == ["limb_seek_care"])

        fixture.run(seconds: 95)
        #expect(coordinator.state.stateID == "limb_wait")
        #expect(fixture.audio.played.filter { $0 == "limb_seek_care" }.count == 4, "re-asked every 30 s")
        #expect(fixture.logDetails(.callPrompted).isEmpty)
        #expect(fixture.audio.metronome.isEmpty)
        expectOffline(fixture)
    }

    // MARK: - A collapse

    /// With no reply the breathing question goes to the call step in 30 s, which is one tap from compressions.
    @Test(arguments: ["limb_start", "limb_flags", "limb_splint", "limb_wait", "limb_danger"])
    func aTappedCollapseFromAnyStepIsOneTapFromCompressingWithin30Seconds(id: String) throws {
        let fixture = try inFlow()
        let coordinator = fixture.coordinator
        coordinator.force(stateID: id)
        #expect(coordinator.state.stateID == id)
        fixture.audio.clearCalls()

        coordinator.perform(.patientUnresponsive)
        #expect(coordinator.state.stateID == "intake_breathing")
        #expect(fixture.audio.calls.contains(.cut), "whatever was playing stops at once")
        #expect(explanation(fixture) == nil, "the why panel is about a flow they've left")

        fixture.run(seconds: 30.2)
        #expect(coordinator.state.stateID == "call_911")
        coordinator.perform(.startCpr)
        #expect(coordinator.state.stateID == "compressions")
        #expect(coordinator.showsPulse)
        expectOffline(fixture)
    }

    // MARK: - The screen

    /// This step has no timer, and the audio can be down, so all of its care stays up, re-ask or not.
    @Test func theDangerStepKeepsItsCareOnScreen() throws {
        let fixture = try inFlow()
        fixture.coordinator.perform(.done)
        fixture.coordinator.perform(.yes)
        let care = "\(text(fixture, "limb_danger_care")) \(text(fixture, "limb_tourniquet"))"
        for _ in 0..<2 {
            fixture.run(seconds: 30.2)
            #expect(fixture.coordinator.instruction == text(fixture, "call_911"))
            #expect(fixture.coordinator.stepDetail == care)
            #expect(fixture.coordinator.prompt == nil)
        }
    }

    @Test func aReAskInTheWaitDoesNotPileOntoTheScreen() throws {
        let fixture = try inFlow()
        fixture.coordinator.perform(.done)
        fixture.coordinator.perform(.no)
        fixture.coordinator.perform(.done)
        fixture.run(seconds: 30.2)
        #expect(fixture.audio.played.filter { $0 == "limb_seek_care" }.count == 2)
        #expect(fixture.coordinator.prompt == nil)
    }

    // MARK: - Stage control

    @Test func aForcedWalkIntoTheFlowIsNobodysChoice() throws {
        let fixture = try Fixture(bundle: try mergedBundle())
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.force(stateID: "limb_wait")
        #expect(coordinator.state.stateID == "limb_wait")

        let entered = coordinator.log.entries.filter { $0.kind == .flowEntered }
        #expect(entered.map(\.detail) == ["possible_broken_bone"])
        #expect(entered.first?.source == .system)
        #expect(explanation(fixture)?.chooser == .neither)
        #expect(fixture.logDetails(.answer).isEmpty, "invented answers aren't recorded as fact")
    }
}
