import Foundation
@testable import HealthAISim
@testable import RescueCore
import RescueLive
import Testing

/// Hands-free: the rescuer's own words press the button they name, as a tap would.
@MainActor
@Suite struct VoiceCommandTests {
    private let controls = [
        RescueControl(action: .yes, title: "Yes", role: .answer),
        RescueControl(action: .no, title: "No", role: .answer),
        RescueControl(action: .done, title: "Done, next", role: .step),
        RescueControl(action: .startCpr, title: "Start CPR", role: .primary),
        RescueControl(action: .emsArrived, title: "EMS arrived", role: .stopsCPR),
        RescueControl(action: .notThis, title: "Not this, go back", role: .holdStep),
    ]

    @Test func aButtonsWordsOrACommonWayOfSayingThemPressIt() {
        #expect(VoiceCommands.action(for: "Yes.", among: controls) == .yes)
        #expect(VoiceCommands.action(for: "yeah", among: controls) == .yes)
        #expect(VoiceCommands.action(for: "Um, okay, next please", among: controls) == .done)
        #expect(VoiceCommands.action(for: "Done, next", among: controls) == .done)
        #expect(VoiceCommands.action(for: "Start CPR!", among: controls) == .startCpr)
        #expect(VoiceCommands.action(for: "Nope", among: controls) == .no)
    }

    /// The app's own lines name buttons, and come back through the mic.
    @Test func aButtonInsideASentencePressesNothing() {
        #expect(VoiceCommands.action(for: "If they stop responding, tap Yes", among: controls) == nil)
        #expect(VoiceCommands.action(for: "yes I think so but I'm not sure", among: controls) == nil)
        #expect(VoiceCommands.action(for: "", among: controls) == nil)
    }

    @Test func aButtonNotOnScreenPressesNothing() {
        #expect(VoiceCommands.action(for: "chest pain", among: controls) == nil)
    }

    /// Those take their hold and confirmation, since a mishear there stops compressions.
    @Test func stoppingCPROrLeavingThePathIsNeverByVoice() {
        #expect(VoiceCommands.action(for: "EMS arrived", among: controls) == nil)
        #expect(VoiceCommands.action(for: "Not this, go back", among: controls) == nil)
    }

    // MARK: - In the app

    /// Assess with its awake session up and its opening line finished, so the next words are the rescuer's.
    private func live(openingFinished: Bool = true) async throws -> Fixture {
        let fixture = try Fixture(live: true, bundle: try mergedBundle().startingWithAssessment())
        fixture.coordinator.beginRescue()
        try await waitUntil("an awake connection opened") { fixture.awakeMock.requests.count == 1 }
        fixture.awakeMock.emit(.ready)
        try await waitUntil("the link came up") { fixture.coordinator.liveConnected }
        guard openingFinished else { return fixture }
        for id in fixture.audio.played { fixture.audio.onPhraseFinished?(id) }
        try await fixture.settleInbox()
        fixture.run(seconds: AppCoordinator.ownAudioTail + 0.2)
        return fixture
    }

    private func say(_ words: String, _ fixture: Fixture) async throws {
        fixture.awakeMock.emit(.inputTranscript(words))
        try await waitUntil("the words landed") { fixture.coordinator.heardTranscript.hasSuffix(words) }
    }

    @Test func sayingAButtonPressesItOnceTheRescuerPauses() async throws {
        let fixture = try await live()
        try await say("Not responding", fixture)
        #expect(fixture.coordinator.state.stateID == "assess", "not mid-sentence")
        fixture.run(seconds: AppCoordinator.voiceCommandPause + 0.2)
        #expect(fixture.coordinator.state.stateID == "intake_breathing")
        #expect(fixture.coordinator.voicePressed?.text.hasPrefix("Heard:") == true)
    }

    @Test func aSentenceThatNamesAButtonPressesNothing() async throws {
        let fixture = try await live()
        try await say("I think they're not responding, can you help", fixture)
        fixture.run(seconds: 1)
        #expect(fixture.coordinator.state.stateID == "assess")
    }

    /// Its own line coming back through the mic, while it plays, presses nothing.
    @Test func wordsWhileTheAppIsTalkingPressNothing() async throws {
        let fixture = try await live(openingFinished: false)
        #expect(!fixture.audio.played.isEmpty, "the opening line is still playing")
        try await say("Not responding", fixture)
        fixture.run(seconds: 1)
        #expect(fixture.coordinator.state.stateID == "assess")
    }

    /// The AI's speech is a separate transcript, so it saying a button presses nothing.
    @Test func theAISayingAButtonPressesNothing() async throws {
        let fixture = try await live()
        fixture.awakeMock.emit(.outputTranscript("Not responding"))
        try await waitUntil("its words landed") { fixture.coordinator.saidTranscript.contains("Not responding") }
        fixture.run(seconds: 1)
        #expect(fixture.coordinator.state.stateID == "assess")
    }

    // MARK: - The AI pressing for the rescuer

    private func aiPresses(_ button: String, version: Int? = nil, _ fixture: Fixture) {
        let args: JSONValue = .object([
            "button": .string(button),
            "state_version": .number(Double(version ?? fixture.coordinator.state.version)),
        ])
        fixture.awakeMock.emit(.functionCalls([RealtimeFunctionCall(id: "press-\(button)", name: "press_button", args: args)]))
    }

    private func refused(_ fixture: Fixture) async throws {
        try await waitUntil("the press was refused") {
            fixture.coordinator.assessmentLog.contains { $0.kind == .tool && $0.text.hasPrefix("Didn't press") }
        }
    }

    /// Their words in their own way: the AI reads "they won't answer me" as Not responding.
    @Test func theAIPressesTheButtonTheRescuersWordsChose() async throws {
        let fixture = try await live()
        try await say("they won't answer me at all", fixture)
        aiPresses("patient_unresponsive", fixture)
        try await waitUntil("the step moved") { fixture.coordinator.state.stateID == "intake_breathing" }
        #expect(fixture.coordinator.voicePressed?.text.hasPrefix("Heard:") == true)
    }

    /// With nobody having spoken, a press can only be the AI acting on what it saw.
    @Test func theAICantPressWhenNobodySpoke() async throws {
        let fixture = try await live()
        aiPresses("patient_unresponsive", fixture)
        try await refused(fixture)
        #expect(fixture.coordinator.state.stateID == "assess")
    }

    @Test func aPressAboutAnEarlierStepIsIgnored() async throws {
        let fixture = try await live()
        try await say("they won't answer me", fixture)
        aiPresses("patient_unresponsive", version: fixture.coordinator.state.version - 1, fixture)
        try await refused(fixture)
        #expect(fixture.coordinator.state.stateID == "assess")
    }

    @Test func aButtonThatIsntOnScreenIsIgnored() async throws {
        let fixture = try await live()
        try await say("okay done", fixture)
        aiPresses("pads_on", fixture)
        try await refused(fixture)
        #expect(fixture.coordinator.state.stateID == "assess")
    }
}
