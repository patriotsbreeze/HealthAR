import Foundation
@testable import HealthAISim
@testable import RescueCore
import RescueLive
import Testing

/// The choking flow driven by the AI: "done" moves the hands-on steps on, and "they can cough" or "it
/// came out" only ring the button until a person taps it or says "confirm".
@MainActor
@Suite struct ChokingVoiceTests {
    private func live(at id: String) async throws -> Fixture {
        let fixture = try Fixture(live: true, bundle: try mergedBundle().startingWithAssessment())
        fixture.coordinator.beginRescue()
        try await waitUntil("an awake connection opened") { fixture.awakeMock.requests.count == 1 }
        fixture.awakeMock.emit(.ready)
        try await waitUntil("the link came up") { fixture.coordinator.liveConnected }
        fixture.coordinator.force(stateID: id)
        #expect(fixture.coordinator.state.stateID == id)
        return fixture
    }

    private func say(_ words: String, _ fixture: Fixture) async throws {
        fixture.awakeMock.emit(.inputTranscript(words))
        try await waitUntil("the words landed") { fixture.coordinator.heardTranscript.hasSuffix(words) }
    }

    private func report(_ finding: Finding, _ fixture: Fixture, confidence: Confidence = .high) {
        fixture.coordinator.dispatch(.model(ModelProposal(
            action: .reportFinding(finding, source: .heard, confidence: confidence),
            stateVersion: fixture.coordinator.state.version,
            issuedAt: fixture.clock.now
        )))
    }

    @Test func doneMovesBackBlowsToThrustsWithNoTap() async throws {
        let fixture = try await live(at: "choke_back_blows")
        report(.stepDone, fixture)
        #expect(fixture.coordinator.state.stateID == "choke_thrusts")
        #expect(fixture.coordinator.flowSuggestion == nil)
    }

    @Test func aWorkingCoughRingsYesAndConfirmPressesIt() async throws {
        let fixture = try await live(at: "choke_check")
        report(.canCough, fixture)
        #expect(fixture.coordinator.state.stateID == "choke_check", "only a person chooses the less urgent branch")
        #expect(fixture.coordinator.flowSuggestion == .yes)
        try await say("Okay, confirm.", fixture)
        #expect(fixture.coordinator.state.stateID == "choke_cough")
        #expect(fixture.coordinator.flowSuggestion == nil)
    }

    @Test(arguments: ["choke_back_blows", "choke_thrusts", "choke_cough"])
    func itCameOutRingsTheButtonAndConfirmFinishes(id: String) async throws {
        let fixture = try await live(at: id)
        report(.objectOut, fixture)
        #expect(fixture.coordinator.state.stateID == id)
        #expect(fixture.coordinator.flowSuggestion == .objectOut)
        try await say("confirm", fixture)
        #expect(fixture.coordinator.state.stateID == "choke_out")
    }

    @Test func aTapClearsTheSuggestionToo() async throws {
        let fixture = try await live(at: "choke_thrusts")
        report(.objectOut, fixture)
        fixture.coordinator.perform(.done)
        #expect(fixture.coordinator.state.stateID == "choke_back_blows")
        #expect(fixture.coordinator.flowSuggestion == nil, "a new step, so nothing stale to confirm")
        try await say("confirm", fixture)
        #expect(fixture.coordinator.state.stateID == "choke_back_blows")
    }

    @Test func aLowReportSuggestsNothing() async throws {
        let fixture = try await live(at: "choke_check")
        report(.canCough, fixture, confidence: .low)
        #expect(fixture.coordinator.flowSuggestion == nil)
    }

    /// Off the steps that have the button, there's nothing to ring.
    @Test func nothingToRingWhereTheStepHasNoButton() async throws {
        let fixture = try await live(at: "choke_out")
        report(.objectOut, fixture)
        #expect(fixture.coordinator.flowSuggestion == nil)
        fixture.coordinator.force(stateID: "chest_wait")
        report(.canCough, fixture)
        #expect(fixture.coordinator.flowSuggestion == nil)
    }

    @Test func theAISayingConfirmPressesNothing() async throws {
        let fixture = try await live(at: "choke_check")
        report(.canCough, fixture)
        fixture.awakeMock.emit(.outputTranscript("Say confirm if they can cough."))
        try await waitUntil("its words landed") { fixture.coordinator.saidTranscript.contains("confirm") }
        #expect(fixture.coordinator.state.stateID == "choke_check")
    }
}
