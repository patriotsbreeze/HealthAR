import Foundation
@testable import HealthAISim
import RescueCore
import Testing

/// A report can flip the awake panel to the arrest one under a finger already on its way down.
@MainActor
@Suite struct AnswerSettleTests {
    private func onTheQuestionAfterAReport() throws -> Fixture {
        let fixture = try Fixture(bundle: try mergedBundle())
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.yes)
        coordinator.perform(.triageChest)
        coordinator.dispatch(.model(ModelProposal(
            action: .reportFinding(.unresponsive, source: .heard, confidence: .high),
            stateVersion: coordinator.state.version,
            issuedAt: fixture.clock.now
        )))
        #expect(coordinator.state.stateID == "intake_breathing")
        #expect(coordinator.state.breathingAskedAwake)
        return fixture
    }

    @Test(arguments: [HumanAction.no, .yes, .unsure])
    func anAnswerWaitsOutTheSettleWindow(answer: HumanAction) throws {
        let fixture = try onTheQuestionAfterAReport()
        let coordinator = fixture.coordinator
        coordinator.performAnswer(answer)
        #expect(coordinator.state.stateID == "intake_breathing")

        fixture.run(seconds: 2.2)
        coordinator.performAnswer(answer)
        #expect(coordinator.state.stateID != "intake_breathing")
    }

    @Test func startCPRNeverWaits() throws {
        let fixture = try onTheQuestionAfterAReport()
        fixture.coordinator.perform(.startCpr)
        #expect(fixture.coordinator.state.stateID == "compressions")
    }

    /// The arrest path's own question has no window, and this doesn't give it one.
    @Test func anAnswerFromTheArrestPathNeverWaits() throws {
        let fixture = try Fixture(bundle: try mergedBundle())
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.performAnswer(.no)
        #expect(coordinator.state.stateID == "intake_breathing")
        #expect(!coordinator.state.breathingAskedAwake)
        coordinator.performAnswer(.no)
        #expect(coordinator.state.stateID == "position_patient")
    }
}
