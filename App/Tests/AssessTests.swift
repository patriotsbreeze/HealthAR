import Foundation
@testable import HealthAISim
@testable import RescueCore
import RescueLive
import Testing

/// The opening screen when there's an AI: what it thinks shows as it reports, and a tap still works.
@MainActor
@Suite struct AssessTests {
    private func begun(live: Bool = false) throws -> Fixture {
        let fixture = try Fixture(live: live, bundle: try mergedBundle().startingWithAssessment())
        fixture.coordinator.beginRescue()
        return fixture
    }

    private func report(_ finding: Finding, _ confidence: Confidence, source: ObservationSource = .seen, _ fixture: Fixture) {
        fixture.coordinator.dispatch(.model(ModelProposal(
            action: .reportFinding(finding, source: source, confidence: confidence),
            stateVersion: fixture.coordinator.state.version,
            issuedAt: fixture.clock.now
        )))
    }

    @Test func itOpensOnTheCameraWithOneLineAndNoAssumption() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        #expect(coordinator.isAssessing)
        #expect(fixture.audio.played == ["assess_intro"])
        #expect(coordinator.instruction == "Point the camera at what's happening, and tell me what's going on.")
        #expect(!fixture.audio.played.contains("ask_responsive"), "nothing assumes a collapse")
        #expect(coordinator.assessment.isEmpty)
        #expect(fixture.audio.lastPolicy?.frameUplink == true)
    }

    @Test func whatTheAIThinksShowsAsItReports() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        report(.chestPain, .low, source: .heard, fixture)
        report(.limbInjury, .low, fixture)
        #expect(coordinator.isAssessing, "low reports move nothing")
        #expect(coordinator.assessment.map(\.finding) == [.limbInjury, .chestPain], "newest first")
        #expect(coordinator.assessment.last?.label == "Possible chest pain")
        #expect(coordinator.assessment.last?.certainty == "maybe")
        #expect(coordinator.assessment.last?.source == .heard)
    }

    @Test func aSureReportRoutesAndTheScreenFollows() throws {
        let fixture = try begun()
        report(.chestPain, .medium, source: .heard, fixture)
        #expect(fixture.coordinator.state.stateID == "chest_call")
        #expect(!fixture.coordinator.isAssessing)
    }

    /// The AI seeing a collapse notes it and waits; the rescuer saying so moves it on.
    @Test func aSeenCollapseWaitsAndAHeardOneGoesToTheBreathingQuestion() throws {
        let fixture = try begun()
        report(.unresponsive, .medium, source: .seen, fixture)
        #expect(fixture.coordinator.state.stateID == "assess")
        report(.unresponsive, .medium, source: .heard, fixture)
        #expect(fixture.coordinator.state.stateID == "intake_breathing")
    }

    @Test func theTapsNeverWaitOnTheAI() throws {
        let cpr = try begun()
        cpr.coordinator.perform(.startCpr)
        #expect(cpr.coordinator.state.stateID == "compressions")

        let collapse = try begun()
        collapse.coordinator.perform(.patientUnresponsive)
        #expect(collapse.coordinator.state.stateID == "intake_breathing")

        let awake = try begun()
        awake.coordinator.perform(.patientAwake)
        #expect(awake.coordinator.state.stateID == "triage")
    }

    @Test func withNothingWorkedOutItKeepsWatchingAndWaits() throws {
        let fixture = try begun()
        fixture.run(seconds: 60)
        #expect(fixture.coordinator.isAssessing)
        #expect(fixture.audio.played == ["assess_intro"])
    }

    @Test func theStatusSaysWhenTheAIIsOff() throws {
        let fixture = try begun(live: false)
        #expect(fixture.coordinator.assessStatus == "AI offline. Tap below to say what's happening.")
    }

    @Test func theAIsLastSentenceShowsApartFromTheNotes() async throws {
        let fixture = try Fixture(live: true, bundle: try mergedBundle().startingWithAssessment())
        fixture.coordinator.beginRescue()
        try await waitUntil("a connection was opened") { fixture.awakeMock.requests.count == 1 }
        fixture.awakeMock.emit(.ready)
        try await waitUntil("the link came up") { fixture.coordinator.liveConnected }
        #expect(fixture.coordinator.assessStatus == "Listening. The camera is off.")
        fixture.awakeMock.emit(.outputTranscript("I'm an AI. What happened to him?"))
        try await waitUntil("the line arrived") { fixture.coordinator.lastAISentence != nil }
        #expect(fixture.coordinator.lastAISentence == "What happened to him?")
    }

    @Test func notesStartOverWhenAssessOpensAgain() {
        var log = EventLog()
        log.append([.init(kind: .stateEntered, source: .system, detail: "assess")], at: 0)
        log.append([.init(kind: .observation, source: .aiInferred, detail: "chest_pain,heard,high")], at: 1)
        log.append([.init(kind: .observation, source: .aiInferred, detail: "chest_pain,heard,low")], at: 2)
        log.append([.init(kind: .observation, source: .aiInferred, detail: "ems_arrived,heard,high")], at: 3)
        let notes = AssessmentNote.notes(from: log.entries)
        #expect(notes.map(\.finding) == [.chestPain])
        #expect(notes.first?.confidence == .high, "a later, less sure report doesn't lower what showed")
        log.append([.init(kind: .stateEntered, source: .system, detail: "assess")], at: 4)
        #expect(AssessmentNote.notes(from: log.entries).isEmpty)
    }
}
