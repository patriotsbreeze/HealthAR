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

    /// Assess with its awake session up, so words reach the coordinator as they do on a phone.
    private func live() async throws -> Fixture {
        let fixture = try Fixture(live: true, bundle: try mergedBundle().startingWithAssessment())
        fixture.coordinator.beginRescue()
        try await waitUntil("an awake connection opened") { fixture.awakeMock.requests.count == 1 }
        fixture.awakeMock.emit(.ready)
        try await waitUntil("the link came up") { fixture.coordinator.liveConnected }
        return fixture
    }

    private func say(_ words: String, _ fixture: Fixture) async throws {
        fixture.awakeMock.emit(.inputTranscript(words))
        try await waitUntil("the words landed") { fixture.coordinator.heardTranscript.hasSuffix(words) }
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

    /// The AI's sense of a collapse, seen or heard, only rings the button: in testing it took someone
    /// standing and not answering it for unresponsive. A tap or "confirm" moves it on.
    @Test func aCollapseReportOnlySuggestsTheButton() throws {
        let fixture = try begun()
        report(.unresponsive, .medium, source: .seen, fixture)
        report(.unresponsive, .high, source: .heard, fixture)
        #expect(fixture.coordinator.state.stateID == "assess")
        #expect(fixture.coordinator.assessSuggestion == .notResponding)
        report(.abnormalBreathing, .medium, source: .heard, fixture)
        #expect(fixture.coordinator.state.stateID == "assess")
        #expect(fixture.coordinator.assessSuggestion == .notBreathing)
    }

    @Test func aLowCollapseReportSuggestsNothing() throws {
        let fixture = try begun()
        report(.unresponsive, .low, source: .heard, fixture)
        #expect(fixture.coordinator.assessSuggestion == nil)
    }

    /// Saying "confirm" presses the ringed button, as a tap would.
    @Test(arguments: [
        (Finding.unresponsive, "intake_breathing"), (.notBreathing, "position_patient"), (.abnormalBreathing, "position_patient"),
    ])
    func sayingConfirmPressesTheSuggestion(finding: Finding, to target: String) async throws {
        let fixture = try await live()
        report(finding, .medium, source: .heard, fixture)
        #expect(fixture.coordinator.state.stateID == "assess")
        try await say("Okay, con", fixture)
        #expect(fixture.coordinator.state.stateID == "assess", "half a word is nothing")
        try await say("firm.", fixture)
        #expect(fixture.coordinator.state.stateID == target)
    }

    /// With nothing suggested, "confirm" is just words, and assess keeps waiting.
    @Test func confirmWithNothingSuggestedMovesNothing() async throws {
        let fixture = try await live()
        try await say("confirm", fixture)
        #expect(fixture.coordinator.state.stateID == "assess")
    }

    /// Only whole words: "unconfirmed" doesn't press anything.
    @Test func onlyTheWordConfirmCounts() async throws {
        let fixture = try await live()
        report(.unresponsive, .medium, source: .heard, fixture)
        try await say("that's unconfirmed", fixture)
        #expect(fixture.coordinator.state.stateID == "assess")
    }

    /// The AI's own voice is a separate transcript, so it saying "confirm" presses nothing.
    @Test func theAISayingConfirmPressesNothing() async throws {
        let fixture = try await live()
        report(.unresponsive, .medium, source: .heard, fixture)
        fixture.awakeMock.emit(.outputTranscript("Say confirm if they aren't responding."))
        try await waitUntil("its words landed") { fixture.coordinator.saidTranscript.contains("confirm") }
        #expect(fixture.coordinator.state.stateID == "assess")
    }

    /// Leaving assess clears the suggestion, so a later "confirm" can't press a stale one.
    @Test func leavingAssessClearsTheSuggestion() throws {
        let fixture = try begun()
        report(.unresponsive, .medium, source: .heard, fixture)
        fixture.coordinator.perform(.patientAwake)
        #expect(fixture.coordinator.voiceSuggestion == nil)
        #expect(fixture.coordinator.assessSuggestion == nil)
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
