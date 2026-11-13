import Foundation
@testable import HealthAISim
import RescueAudio
@testable import RescueCore
import RescueLive
import Synchronization
import Testing

private let chunk = Data([1, 2, 3, 4])

/// Keeps the main actor busy, so whatever the router has in hand waits in the inbox, and whatever
/// runs next happens before any of it lands. That's the swap race, held open.
private func holdTheMainActor() {
    usleep(100_000)
}

private func noPackBundle() throws -> ProtocolBundle {
    var bundle = try mergedBundle().closingAwakeVoice()
    bundle.knowledgePack = nil
    return bundle
}

@MainActor
private func connected(bundle: ProtocolBundle? = nil, auditor: Auditor? = nil) async throws -> Fixture {
    let fixture = try Fixture(live: true, auditor: auditor, bundle: try bundle ?? mergedBundle())
    try await fixture.beginAndConnect()
    return fixture
}

/// Yes, and the awake session up.
@MainActor
private func intoTriage(_ fixture: Fixture) async throws {
    fixture.coordinator.perform(.yes)
    #expect(fixture.coordinator.state.stateID == "triage")
    try await waitUntil("an awake connection opened") { fixture.awakeMock.requests.count == 1 }
    fixture.awakeMock.emit(.ready)
    try await waitUntil("the awake link came up") { fixture.coordinator.liveConnected }
}

@MainActor
@Suite struct LiveModeSwapTests {
    // MARK: - The right session for the state

    @Test func eachModeConnectsWithItsOwnPromptAndContract() throws {
        let bundle = try mergedBundle()
        let pack = try #require(bundle.knowledgePack)
        let contracts = AppBoot.toolContracts(in: .main)
        let arrest = try #require(contracts[.arrest])
        let awake = try #require(contracts[.awake])
        #expect(arrest != awake)
        #expect(arrest == (try toolContract()))

        var made: [GeminiLiveConfiguration] = []
        let fixture = try Fixture(bundle: bundle, makeLive: AppBoot.liveFactory(
            key: APIKey("test"),
            contracts: contracts,
            pack: pack,
            appLines: bundle.awakeLines,
            clock: TestClock().reader,
            makeTransport: { configuration in
                made.append(configuration)
                return MockTransport()
            }
        ))
        let coordinator = fixture.coordinator

        coordinator.beginRescue()
        #expect(made.count == 1)
        #expect(made[0].systemInstruction == SystemPrompt.text)
        #expect(made[0].toolContract == arrest)

        coordinator.perform(.yes)
        #expect(made.count == 2)
        #expect(made[1].systemInstruction == SystemPrompt.awake(pack: pack, appLines: bundle.awakeLines))
        #expect(made[1].systemInstruction.contains(pack.topics[0].text))
        #expect(made[1].toolContract == awake)

        coordinator.perform(.triageChest)
        #expect(made.count == 2, "a flow is the same mode as triage")

        coordinator.perform(.patientUnresponsive)
        #expect(made.count == 3)
        #expect(made[2].systemInstruction == SystemPrompt.text)
        #expect(made[2].toolContract == arrest)
    }

    /// A swap mid-rescue mustn't change who is talking, and the app's own lines are in this voice too.
    @Test func bothModesSpeakInTheConfiguredVoice() throws {
        var made: [GeminiLiveConfiguration] = []
        let fixture = try Fixture(bundle: try mergedBundle(), makeLive: AppBoot.liveFactory(
            key: APIKey("test"),
            contracts: AppBoot.toolContracts(in: .main),
            pack: nil,
            voiceName: "Kore",
            clock: TestClock().reader,
            makeTransport: { configuration in
                made.append(configuration)
                return MockTransport()
            }
        ))
        fixture.coordinator.beginRescue()
        fixture.coordinator.perform(.yes)
        fixture.coordinator.perform(.patientUnresponsive)
        #expect(made.count == 3)
        #expect(made.map(\.voiceName) == ["Kore", "Kore", "Kore"])

        var unset: [GeminiLiveConfiguration] = []
        let plain = try Fixture(bundle: try mergedBundle(), makeLive: AppBoot.liveFactory(
            key: APIKey("test"), contracts: AppBoot.toolContracts(in: .main), pack: nil, clock: TestClock().reader,
            makeTransport: { configuration in
                unset.append(configuration)
                return MockTransport()
            }
        ))
        plain.coordinator.beginRescue()
        #expect(unset.first?.voiceName == nil)
    }

    @Test func aModeWithNoContractStaysOfflineAndTheOtherStillRuns() throws {
        var made = 0
        let fixture = try Fixture(bundle: try mergedBundle(), makeLive: AppBoot.liveFactory(
            key: APIKey("test"),
            contracts: AppBoot.toolContracts(in: .main).filter { $0.key == .arrest },
            pack: nil,
            clock: TestClock().reader,
            makeTransport: { _ in
                made += 1
                return MockTransport()
            }
        ))
        fixture.coordinator.beginRescue()
        #expect(made == 1)
        fixture.coordinator.perform(.yes)
        #expect(made == 1)
        #expect(fixture.coordinator.linkLabel == "Offline protocol")
        #expect(fixture.audio.lastPolicy?.audioMode == .playbackOnly, "nothing to hear for, so the mic stays off")
        fixture.coordinator.perform(.patientUnresponsive)
        #expect(made == 2)
    }

    @Test func aSwapStopsTheOldSessionAndSeedsTheNewOneWithThisState() async throws {
        let fixture = try await connected()
        fixture.coordinator.perform(.yes)

        try await waitUntil("the arrest socket closed") { fixture.mock.closedCount == 1 }
        try await waitUntil("an awake socket opened") { fixture.awakeMock.requests.count == 1 }
        #expect(fixture.mock.openCount == 0)
        #expect(fixture.awakeMock.requests[0] == RealtimeConnectRequest(resumeHandle: nil, seedsHistory: true))

        fixture.awakeMock.emit(.ready)
        try await waitUntil("the seed went up") { !fixture.awakeMock.sentBriefs.isEmpty }
        let seed = try #require(fixture.awakeMock.sentBriefs.first)
        #expect(seed.stateID == "triage")
        #expect(fixture.awakeMock.sent.first == .stateBrief(seed, seed: true))
        #expect(seed.text.contains("you_may_speak=true"))

        // And the way back.
        fixture.coordinator.perform(.patientUnresponsive)
        #expect(fixture.coordinator.state.stateID == "intake_breathing")
        try await waitUntil("the awake socket closed") { fixture.awakeMock.closedCount == 1 }
        try await waitUntil("a new arrest socket opened") { fixture.mock.requests.count == 2 }
        #expect(fixture.mock.requests[1] == RealtimeConnectRequest(resumeHandle: nil, seedsHistory: true))
        fixture.mock.emit(.ready)
        try await waitUntil("the seed went up") { fixture.mock.sentBriefs.last?.stateID == "intake_breathing" }
        #expect(!fixture.mock.sentBriefs.last!.text.contains("mode="), "an arrest session gets the brief it always got")
    }

    /// A timeout leaves an awake state by itself only into another one. The tap that goes the other
    /// way is covered above, and a report takes the same path.
    @Test func aModelReportOfACollapseSwapsToo() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        let version = fixture.coordinator.state.version
        fixture.awakeMock.emit(.functionCalls([reportFindingCall("unresponsive", version: version)]))
        try await waitUntil("the report moved the state") { fixture.coordinator.state.stateID == "intake_breathing" }
        try await waitUntil("an arrest socket opened") { fixture.mock.requests.count == 2 }
        try await waitUntil("the awake socket closed") { fixture.awakeMock.openCount == 0 }
    }

    @Test func aCardKeepsWhateverIsRunning() async throws {
        // The awake session stays through handoff, and the arrest one through the static card.
        let awake = try await connected()
        try await intoTriage(awake)
        awake.coordinator.perform(.emsArrived)
        #expect(awake.coordinator.state.stateID == "handoff")
        #expect(awake.coordinator.liveConnected)
        #expect(awake.awakeMock.closedCount == 0)
        #expect(awake.mock.requests.count == 1)

        let arrest = try Fixture(live: true)
        try await arrest.beginAndConnect()
        arrest.coordinator.perform(.yes)
        #expect(arrest.coordinator.state.stateID == "responsive_patient")
        #expect(arrest.coordinator.liveConnected)
        try await Task.sleep(for: .milliseconds(30))
        #expect(arrest.mock.closedCount == 0)
        #expect(arrest.awakeMock.requests.isEmpty)
    }

    @Test func aRestartGoesBackToAnArrestSession() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.coordinator.restartRescue()
        #expect(fixture.coordinator.state.stateID == "intake_responsive")
        try await waitUntil("a second arrest socket opened") { fixture.mock.requests.count == 2 }
        try await waitUntil("the awake socket closed") { fixture.awakeMock.openCount == 0 }
        #expect(fixture.mock.openCount == 1)
    }

    @Test func withNoKeyEverythingStaysOffline() throws {
        let fixture = try Fixture(bundle: try mergedBundle())
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.yes)
        #expect(coordinator.state.stateID == "triage")
        #expect(coordinator.linkLabel == "Offline protocol")
        #expect(fixture.audio.lastPolicy?.audioMode == .playbackOnly)
        coordinator.perform(.patientUnresponsive)
        #expect(coordinator.linkLabel == "Offline protocol")
        #expect(fixture.mock.requests.isEmpty)
        #expect(fixture.awakeMock.requests.isEmpty)
    }

    // MARK: - The chip, while nothing is hearing

    @Test func theChipSaysSoWhileTheSwapIsDown() async throws {
        let fixture = try await connected()
        let coordinator = fixture.coordinator
        #expect(coordinator.linkLabel == "Live")

        coordinator.perform(.yes)
        #expect(!coordinator.liveConnected)
        #expect(coordinator.linkLabel == "AI switching, can't hear")

        try await waitUntil("an awake socket opened") { fixture.awakeMock.requests.count == 1 }
        fixture.awakeMock.emit(.ready)
        try await waitUntil("the link came up") { coordinator.liveConnected }
        #expect(coordinator.linkLabel == "Live")
    }

    @Test func aSwapThatFailsStopsSayingSwitching() async throws {
        let fixture = try await connected()
        fixture.coordinator.perform(.yes)
        try await waitUntil("an awake socket opened") { fixture.awakeMock.requests.count == 1 }
        fixture.awakeMock.emit(.closed(.networkFailure(code: nil)))
        try await waitUntil("the attempt failed") { fixture.coordinator.linkLabel == "Offline protocol" }
    }

    @Test func tapsAndLocalGuidanceCarryOnDuringTheSwap() async throws {
        let fixture = try await connected()
        let coordinator = fixture.coordinator
        coordinator.perform(.yes)
        #expect(!coordinator.liveConnected)
        #expect(fixture.audio.played.contains("triage_ask"))

        coordinator.perform(.triageChest)
        #expect(coordinator.state.stateID == "chest_call")
        #expect(fixture.audio.played.contains("chest_possible"))
        fixture.run(seconds: 15.2)
        #expect(coordinator.state.stateID == "chest_aspirin_check", "the timer doesn't wait on the session")
    }

    @Test func theSwapTimeShowsOnTheHUD() async throws {
        let fixture = try await connected()
        fixture.coordinator.perform(.yes)
        try await waitUntil("an awake socket opened") { fixture.awakeMock.requests.count == 1 }
        fixture.clock.advance(1.5)
        fixture.awakeMock.emit(.ready)
        try await waitUntil("the link came up") { fixture.coordinator.liveConnected }
        let times = try #require(fixture.coordinator.timings[.modeSwap])
        #expect(times.count == 1)
        #expect(abs(times[0] - 1.5) < 1e-6)
        #expect(LatencyHUD.metrics(for: fixture.coordinator.timings).contains { $0.1 == "Mode swap" })
    }

    /// An arrest-only rescue never swaps, so its HUD has the rows it always had.
    @Test func anArrestOnlyHUDHasNoSwapRow() async throws {
        let fixture = try await connected()
        fixture.coordinator.perform(.no)
        #expect(LatencyHUD.metrics(for: fixture.coordinator.timings).map(\.1) == [
            "Live setup", "Reconnect gap", "Speech end to tool", "Speech end to voice",
        ])
    }

    // MARK: - What comes late

    @Test func aReportFromTheOldSessionNeverReachesTheEngine() async throws {
        let fixture = try await connected()
        let coordinator = fixture.coordinator
        let version = coordinator.state.version
        fixture.mock.emit(.functionCalls([reportFindingCall("not_breathing", version: version + 1)]))
        fixture.mock.emit(.inputTranscript("he's not breathing"))
        fixture.mock.emit(.outputTranscript("Check his pulse."))
        fixture.mock.emit(.turnComplete)
        holdTheMainActor()

        coordinator.perform(.yes)
        try await fixture.settleInbox()

        #expect(coordinator.state.stateID == "triage", "stale by version or not, it isn't this session's to judge")
        #expect(coordinator.modelCalls.isEmpty)
        #expect(fixture.logDetails(.proposalRejected).isEmpty)
        #expect(fixture.logDetails(.finding).isEmpty)
        #expect(fixture.logDetails(.sentinelFlag).isEmpty)
        #expect(coordinator.heardTranscript.isEmpty)
        #expect(coordinator.saidTranscript.isEmpty)
    }

    /// The same thing with no swap, so the test above can't pass by the events simply going nowhere.
    @Test func theSameReportDoesLandWithNoSwap() async throws {
        let fixture = try await connected()
        let coordinator = fixture.coordinator
        fixture.mock.emit(.functionCalls([reportFindingCall("not_breathing", version: coordinator.state.version)]))
        holdTheMainActor()
        try await fixture.settleInbox()
        #expect(coordinator.modelCalls.count == 1)
        #expect(coordinator.state.stateID == "call_911")
    }

    @Test func aLateConnectFromTheOldSessionCantSayLive() async throws {
        let fixture = try Fixture(live: true, bundle: try mergedBundle())
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        try await waitUntil("an arrest socket opened") { fixture.mock.requests.count == 1 }
        fixture.mock.emit(.ready)
        holdTheMainActor()

        coordinator.perform(.yes)
        try await fixture.settleInbox()
        #expect(!coordinator.liveConnected)
        #expect(coordinator.linkLabel == "AI switching, can't hear")
    }

    @Test func aLateDisconnectFromTheOldSessionTouchesNothing() async throws {
        let fixture = try await connected()
        let coordinator = fixture.coordinator
        fixture.mock.emit(.closed(.networkFailure(code: nil)))
        holdTheMainActor()

        coordinator.perform(.yes)
        try await fixture.settleInbox()
        #expect(coordinator.lastDisconnect == nil)
        #expect(coordinator.linkLabel == "AI switching, can't hear")
    }

    @Test func aLateAuditorAnswerFromTheOldSessionIsDropped() async throws {
        let answer = auditorHTTP(category: "reassurance")
        let slow: HTTPClient = { request in
            try? await Task.sleep(for: .milliseconds(150))
            return try await answer(request)
        }
        let fixture = try await connected(auditor: Auditor(apiKey: APIKey("test"), http: slow))
        fixture.mock.emit(.outputTranscript("It all sounded good to me."))
        fixture.mock.emit(.turnComplete)
        try await waitUntil("the turn ended") { fixture.audio.calls.contains(.turnEnded) }
        try await fixture.settleInbox()

        fixture.coordinator.perform(.yes)
        try await Task.sleep(for: .milliseconds(400))
        try await fixture.settleInbox()
        #expect(fixture.logDetails(.sentinelFlag).isEmpty)
        #expect(!fixture.audio.played.contains("correct_reassure"))
    }

    /// The router is on its own thread, so nothing above can catch it between its check and the audio.
    @Test func theGateTurnsAwayAReplacedSessionsAudio() {
        let gate = UplinkGate()
        gate.setPolicy(RuntimePolicy(modelSpeechOpen: true, micUplink: true, frameUplink: true, audioMode: .full))
        gate.setCurrentSession(1)

        var plays = 0
        #expect(gate.admitModelAudio(session: 1) { plays += 1 } == .played)
        #expect(plays == 1)

        gate.setCurrentSession(2, mode: .awake)
        #expect(gate.admitModelAudio(session: 1) { plays += 1 } == .stale)
        #expect(!gate.endModelTurn(session: 1) { plays += 1 })
        #expect(plays == 1)

        gate.setCurrentSession(nil)
        #expect(gate.admitModelAudio(session: 2) { plays += 1 } == .stale)
        #expect(plays == 1)
    }

    @Test func theGateStillClosesTheCurrentSessionsAudio() {
        let gate = UplinkGate()
        gate.setPolicy(RuntimePolicy(modelSpeechOpen: false, micUplink: true, frameUplink: true, audioMode: .full))
        gate.setCurrentSession(1)
        var plays = 0
        #expect(gate.admitModelAudio(session: 1) { plays += 1 } == .closed)
        gate.setPolicy(RuntimePolicy(modelSpeechOpen: true, micUplink: true, frameUplink: true, audioMode: .full))
        gate.setBargeIn(true)
        #expect(gate.admitModelAudio(session: 1) { plays += 1 } == .closed)
        #expect(plays == 0)
    }

    @Test func modelAudioFromTheOldSessionNeverPlays() async throws {
        let fixture = try await connected()
        // The path is live, so what follows can't pass by nothing ever arriving.
        fixture.mock.emit(.audio(chunk))
        try await waitUntil("it played") { fixture.audio.calls.contains(.modelAudio(chunk)) }
        fixture.audio.clearCalls()
        // Same race: this is on its way through the router as the tap lands.
        fixture.mock.emit(.audio(chunk))
        fixture.coordinator.perform(.yes)
        let swappedAt = fixture.audio.calls.lastIndex(of: .flush)
        try await fixture.settleInbox()
        try await Task.sleep(for: .milliseconds(30))

        // It may have got in before the swap, but only ever ahead of the flush that clears it.
        if let played = fixture.audio.calls.firstIndex(of: .modelAudio(chunk)) {
            #expect(played < (swappedAt ?? 0))
        }
    }

    // MARK: - Rapid transitions

    /// Whatever the taps did, one socket is left open, on the mode the last state needs.
    @Test(arguments: [
        ([HumanAction.yes, .patientUnresponsive, .notThis, .yes], "watch_breathing", LiveMode.arrest),
        ([.yes, .patientUnresponsive], "intake_breathing", .arrest),
        ([.yes, .triageChest, .notThis], "triage", .awake),
        ([.yes, .triageChest, .notThis, .triageLimb, .startCpr], "compressions", .arrest),
        ([.no, .yes, .patientAwake, .triageOpen], "triage", .awake),
        ([.no, .yes, .patientAwake, .triageOpen, .patientUnresponsive, .yes, .patientAwake, .triageOpen, .triageOther], "general_talk", .awake),
    ])
    func rapidTapsEndOnTheRightModeWithNoLeak(taps: [HumanAction], ends state: String, mode: LiveMode) async throws {
        let fixture = try await connected()
        for tap in taps { fixture.coordinator.perform(tap) }
        #expect(fixture.coordinator.state.stateID == state)

        let (winner, loser) = mode == .awake ? (fixture.awakeMock, fixture.mock) : (fixture.mock, fixture.awakeMock)
        try await waitUntil("the sockets settled") { winner.openCount == 1 && loser.openCount == 0 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(winner.openCount == 1)
        #expect(loser.openCount == 0)

        // And that one is the one in charge.
        winner.emit(.ready)
        try await waitUntil("the link came up") { fixture.coordinator.liveConnected }
        try await waitUntil("its seed names the last state") { winner.sentBriefs.last?.stateID == state }
    }

    @Test func manySwapsLeaveOneSocket() async throws {
        let fixture = try await connected()
        let coordinator = fixture.coordinator
        coordinator.perform(.no)
        coordinator.perform(.yes)
        for _ in 0..<25 {
            coordinator.perform(.patientAwake)
            coordinator.perform(.triageOpen)
            #expect(coordinator.state.stateID == "triage")
            coordinator.perform(.patientUnresponsive)
            coordinator.perform(.yes)
            #expect(coordinator.state.stateID == "watch_breathing")
        }
        try await waitUntil("the sockets settled") { fixture.mock.openCount == 1 && fixture.awakeMock.openCount == 0 }
        #expect(fixture.mock.requests.count == 26)
        #expect(fixture.awakeMock.requests.count == 25)
    }

    /// A socket count can't see a session that stays in memory with its tasks.
    @Test func aSwappedOutSessionIsLetGo() async throws {
        final class Held { weak var session: LiveSession? }
        var held: [Held] = []
        let clock = TestClock()
        let fixture = try Fixture(bundle: try mergedBundle(), makeLive: { mode in
            let session = LiveSession(transport: MockTransport(), clock: clock.reader, mode: mode)
            let entry = Held()
            entry.session = session
            held.append(entry)
            return LiveStack(session: session, auditor: nil)
        })
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.no)
        coordinator.perform(.yes)
        for _ in 0..<5 {
            coordinator.perform(.patientAwake)
            coordinator.perform(.triageOpen)
            coordinator.perform(.patientUnresponsive)
            coordinator.perform(.yes)
        }
        #expect(held.count == 11)
        try await waitUntil("all but the last were let go") { held.dropLast().allSatisfy { $0.session == nil } }
        #expect(held.last?.session != nil)
    }

    // MARK: - A handle never crosses

    @Test func aHandleStaysInItsModeAndDiesWithItsSession() async throws {
        let fixture = try await connected()
        fixture.mock.emit(.resumption(handle: "arrest-handle", resumable: true))
        fixture.mock.emit(.goAway(secondsLeft: 1))
        try await waitUntil("a goAway reconnects within the mode") { fixture.mock.requests.count == 2 }
        #expect(fixture.mock.requests[1].resumeHandle == "arrest-handle")
        #expect(fixture.awakeMock.requests.isEmpty)
        fixture.mock.emit(.ready)
        try await waitUntil("it came back") { fixture.coordinator.liveConnected }

        fixture.coordinator.perform(.yes)
        try await waitUntil("an awake socket opened") { fixture.awakeMock.requests.count == 1 }
        #expect(fixture.awakeMock.requests[0].resumeHandle == nil)

        fixture.awakeMock.emit(.ready)
        try await waitUntil("the awake link came up") { fixture.coordinator.liveConnected }
        fixture.awakeMock.emit(.resumption(handle: "awake-handle", resumable: true))
        fixture.awakeMock.emit(.goAway(secondsLeft: 1))
        try await waitUntil("a goAway reconnects within the mode") { fixture.awakeMock.requests.count == 2 }
        #expect(fixture.awakeMock.requests[1].resumeHandle == "awake-handle")
        #expect(fixture.mock.requests.count == 2)

        fixture.coordinator.perform(.patientUnresponsive)
        try await waitUntil("a new arrest socket opened") { fixture.mock.requests.count == 3 }
        #expect(fixture.mock.requests[2].resumeHandle == nil, "not arrest-handle, and not awake-handle")
    }

    // MARK: - Findings by mode, through the whole path

    @Test func anArrestSessionsRouterRefusesAnAwakeFinding() async throws {
        let fixture = try await connected()
        let coordinator = fixture.coordinator
        let call = reportFindingCall("chest_pain", version: coordinator.state.version)
        fixture.mock.emit(.functionCalls([call]))
        try await waitUntil("the refusal went up") {
            fixture.mock.sent.contains { if case let .toolResponses(responses) = $0 { responses.first?.status == .rejected } else { false } }
        }
        try await fixture.settleInbox()
        #expect(coordinator.modelCalls.isEmpty)
        #expect(coordinator.state.stateID == "intake_responsive")
    }

    @Test func anAwakeSessionsRouterTakesAnAwakeFindingAndRefusesAReassuringOne() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        let coordinator = fixture.coordinator

        fixture.awakeMock.emit(.functionCalls([reportFindingCall("breathing_normally", version: coordinator.state.version)]))
        try await waitUntil("the refusal went up") {
            fixture.awakeMock.sent.contains { if case let .toolResponses(responses) = $0 { responses.first?.status == .rejected } else { false } }
        }
        try await fixture.settleInbox()
        #expect(coordinator.modelCalls.isEmpty)

        fixture.awakeMock.emit(.functionCalls([reportFindingCall("chest_pain", version: coordinator.state.version, id: "call-2")]))
        try await waitUntil("the report routed") { coordinator.state.stateID == "chest_call" }
        #expect(coordinator.modelCalls.count == 1)
        #expect(coordinator.flowExplanation?.headline == "Possible heart attack. Not a diagnosis.")
    }

    // MARK: - Validators by mode

    @Test func theAwakeValidatorsCatchWhatTheArrestOnesDoNot() async throws {
        let fixture = try await connected()
        fixture.mock.emit(.outputTranscript("It's definitely a heart attack. "))
        try await waitUntil("it was heard") { !fixture.coordinator.saidTranscript.isEmpty }
        #expect(fixture.logDetails(.sentinelFlag).isEmpty, "the arrest list has nothing to say about this")

        // Past the turn, so it isn't the same line twice.
        fixture.mock.emit(.turnComplete)
        try await fixture.settleInbox()

        try await intoTriage(fixture)
        fixture.awakeMock.emit(.outputTranscript("It's definitely a heart attack. "))
        try await waitUntil("the flag landed") { fixture.logDetails(.sentinelFlag) == ["diagnosis"] }
        #expect(fixture.audio.played.contains("correct_diagnosis"), "from the awake map")
        #expect(fixture.coordinator.state.stateID == "triage", "a flag never changes the step")
    }

    @Test func theArrestValidatorsStayOffAnAwakeSessionsOrdinaryLines() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.awakeMock.emit(.outputTranscript("They should rest, and aspirin could come up. "))
        try await waitUntil("it was heard") { !fixture.coordinator.saidTranscript.isEmpty }
        #expect(fixture.logDetails(.sentinelFlag).isEmpty)
    }

    /// `finishModelTurn` is where the auditor's profile and the last word are decided.
    @Test func theAuditorTakesTheProfileOfTheState() async throws {
        let auditor = Auditor(apiKey: APIKey("test"), http: auditorHTTP(category: "diagnosis"))
        let fixture = try await connected(auditor: auditor)
        fixture.mock.emit(.outputTranscript("A harmless line."))
        fixture.mock.emit(.turnComplete)
        try await waitUntil("the turn ended") { fixture.audio.calls.contains(.turnEnded) }
        try await Task.sleep(for: .milliseconds(100))
        try await fixture.settleInbox()
        #expect(fixture.logDetails(.sentinelFlag).isEmpty, "an arrest audit can't answer with an awake category")

        try await intoTriage(fixture)
        fixture.audio.clearCalls()
        fixture.awakeMock.emit(.outputTranscript("A harmless line."))
        fixture.awakeMock.emit(.turnComplete)
        try await waitUntil("the auditor's flag landed") { fixture.logDetails(.sentinelFlag) == ["diagnosis"] }
        // Awake, the auditor only keeps the record.
        #expect(!fixture.audio.played.contains { $0.hasPrefix("correct_") })
        #expect(!fixture.audio.calls.contains(.flush))
        #expect(fixture.gate.modelAudioOpen, "nothing holds the AI's voice")
    }

    @Test func theLastWordOfAnAwakeTurnIsChecked() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.awakeMock.emit(.outputTranscript("It's definitely a heart attack"))
        try await waitUntil("it was heard") { !fixture.coordinator.saidTranscript.isEmpty }
        #expect(fixture.logDetails(.sentinelFlag).isEmpty, "the last word might yet change")
        fixture.awakeMock.emit(.turnComplete)
        try await waitUntil("the flag landed") { fixture.logDetails(.sentinelFlag) == ["diagnosis"] }
    }

    @Test func aSwapForgetsTheLineInProgress() async throws {
        let fixture = try await connected()
        fixture.mock.emit(.outputTranscript("Check his "))
        try await waitUntil("it was heard") { !fixture.coordinator.saidTranscript.isEmpty }

        try await intoTriage(fixture)
        fixture.awakeMock.emit(.outputTranscript("pulse now. "))
        try await waitUntil("it was heard") { fixture.coordinator.saidTranscript.contains("pulse now") }
        #expect(fixture.logDetails(.sentinelFlag).isEmpty, "two sessions never made one sentence")
    }

    @Test func aSwapResetsWhatWasAlreadyFlagged() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.awakeMock.emit(.outputTranscript("Check his pulse. "))
        try await waitUntil("the first flag") { fixture.logDetails(.sentinelFlag).count == 1 }

        fixture.coordinator.perform(.patientUnresponsive)
        try await waitUntil("a new arrest socket opened") { fixture.mock.requests.count == 2 }
        fixture.mock.emit(.ready)
        try await waitUntil("the link came up") { fixture.coordinator.liveConnected }
        fixture.mock.emit(.outputTranscript("Check his pulse. "))
        try await waitUntil("the same line is caught again") { fixture.logDetails(.sentinelFlag).count == 2 }
    }

    /// The swap flushes the audio, but the record still shows the line, with nobody corrected for it.
    @Test func aSwapRecordsAFlagStillWaitingOnItsNextWord() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        for chunk in [" Give", " him", " two", " pills"] { fixture.awakeMock.emit(.outputTranscript(chunk)) }
        try await waitUntil("it was heard") { fixture.coordinator.saidTranscript.hasSuffix("two pills") }
        #expect(fixture.logDetails(.sentinelFlag).isEmpty, "the last word could still have been pillows")

        fixture.audio.clearCalls()
        fixture.coordinator.perform(.patientUnresponsive)
        #expect(fixture.coordinator.state.stateID == "intake_breathing")
        #expect(fixture.logDetails(.sentinelFlag) == ["dose"])
        #expect(!fixture.audio.played.contains { $0.hasPrefix("correct_") })
    }
}

// MARK: - So the AI actually speaks

@MainActor
@Suite struct AISpeaksFirstTests {
    @Test func oneKickOnceTriageAskFinishes() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.run(seconds: 1)
        #expect(fixture.awakeMock.kicks == 0, "triage_ask hasn't finished")

        fixture.audio.onPhraseFinished?("triage_ask")
        try await waitUntil("the kick went up") { fixture.awakeMock.kicks == 1 }

        fixture.audio.onPhraseFinished?("triage_ask")
        fixture.run(seconds: 5)
        try await fixture.settleInbox()
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.awakeMock.kicks == 1)
    }

    @Test func aKickWaitsForASessionThatComesUpLater() async throws {
        let fixture = try await connected()
        fixture.coordinator.perform(.yes)
        fixture.audio.onPhraseFinished?("triage_ask")
        try await fixture.settleInbox()
        try await waitUntil("an awake socket opened") { fixture.awakeMock.requests.count == 1 }
        #expect(fixture.awakeMock.kicks == 0)

        fixture.awakeMock.emit(.ready)
        try await waitUntil("the kick went up") { fixture.awakeMock.kicks == 1 }
        // After the seed, so it's a question the model can answer, and not the end of its history.
        guard case .stateBrief(_, seed: true)? = fixture.awakeMock.sent.first else {
            Issue.record("the seed wasn't first")
            return
        }
    }

    @Test func aReconnectDoesNotKickAgain() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.audio.onPhraseFinished?("triage_ask")
        try await waitUntil("the kick went up") { fixture.awakeMock.kicks == 1 }

        fixture.awakeMock.emit(.closed(.networkFailure(code: nil)))
        try await waitUntil("a reconnect") { fixture.awakeMock.requests.count == 2 }
        fixture.awakeMock.emit(.ready)
        try await waitUntil("the link came back") { fixture.coordinator.liveConnected }
        fixture.run(seconds: 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.awakeMock.kicks == 1)
    }

    @Test func comingBackToTriageDoesNotKickAgain() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.audio.onPhraseFinished?("triage_ask")
        try await waitUntil("the kick went up") { fixture.awakeMock.kicks == 1 }
        fixture.coordinator.perform(.triageChest)
        fixture.coordinator.perform(.notThis)
        #expect(fixture.coordinator.state.stateID == "triage")
        fixture.audio.onPhraseFinished?("triage_ask")
        try await fixture.settleInbox()
        fixture.run(seconds: 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.awakeMock.kicks == 1)
    }

    @Test func aNewRescueGetsItsOwnKick() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.audio.onPhraseFinished?("triage_ask")
        try await waitUntil("the kick went up") { fixture.awakeMock.kicks == 1 }

        fixture.coordinator.restartRescue()
        try await waitUntil("a second arrest socket opened") { fixture.mock.requests.count == 2 }
        fixture.coordinator.perform(.yes)
        try await waitUntil("a second awake socket opened") { fixture.awakeMock.requests.count == 2 }
        fixture.awakeMock.emit(.ready)
        try await waitUntil("the link came up") { fixture.coordinator.liveConnected }
        fixture.audio.onPhraseFinished?("triage_ask")
        try await waitUntil("the new kick went up") { fixture.awakeMock.kicks == 2 }
    }

    /// The arrest session's own behaviour, unchanged: nothing asks it to speak first.
    @Test func noKickInAnArrestSession() async throws {
        let fixture = try await connected()
        fixture.audio.onPhraseFinished?("triage_ask")
        fixture.audio.onPhraseFinished?("ask_responsive")
        fixture.run(seconds: 2)
        try await fixture.settleInbox()
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.mock.kicks == 0)
    }

    @Test(arguments: ["general_talk", "chest_wait", "limb_wait"])
    func noKickOutsideTriage(id: String) async throws {
        let fixture = try await connected()
        fixture.coordinator.force(stateID: id)
        try await waitUntil("an awake socket opened") { fixture.awakeMock.requests.count == 1 }
        fixture.awakeMock.emit(.ready)
        try await waitUntil("the link came up") { fixture.coordinator.liveConnected }
        fixture.audio.onPhraseFinished?("triage_ask")
        fixture.run(seconds: 2)
        try await fixture.settleInbox()
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.awakeMock.kicks == 0)
    }

    @Test func leavingTriageBeforeTheSessionIsUpCancelsTheKick() async throws {
        let fixture = try await connected()
        fixture.coordinator.perform(.yes)
        fixture.audio.onPhraseFinished?("triage_ask")
        try await fixture.settleInbox()
        fixture.coordinator.perform(.triageChest)
        try await waitUntil("an awake socket opened") { fixture.awakeMock.requests.count == 1 }
        fixture.awakeMock.emit(.ready)
        try await waitUntil("the link came up") { fixture.coordinator.liveConnected }
        fixture.run(seconds: 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.awakeMock.kicks == 0)
    }

    @Test func aKickWaitsForAnOpenDispatcherSheet() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.coordinator.setDispatcher(open: true)
        fixture.audio.onPhraseFinished?("triage_ask")
        try await fixture.settleInbox()
        fixture.run(seconds: 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.awakeMock.kicks == 0, "nothing the model said could be heard")

        fixture.coordinator.setDispatcher(open: false)
        fixture.run(seconds: 0.4)
        try await waitUntil("the kick went up") { fixture.awakeMock.kicks == 1 }
    }

    /// Client content can interrupt a turn, and a person's own words are the better prompt.
    @Test func aKickWaitsForSomeoneTalkingAndForTheAnswer() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.audio.onSpeechStarted?()
        fixture.audio.onPhraseFinished?("triage_ask")
        try await fixture.settleInbox()
        fixture.run(seconds: 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.awakeMock.kicks == 0)

        fixture.audio.onSpeechEnded?()
        try await fixture.settleInbox()
        fixture.run(seconds: 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.awakeMock.kicks == 0, "the AI has someone to answer")

        fixture.awakeMock.emit(.audio(chunk))
        try await waitUntil("it answered") { fixture.coordinator.state.modelTurnActive }
        fixture.awakeMock.emit(.turnComplete)
        try await waitUntil("the turn ended") { !fixture.coordinator.state.modelTurnActive }
        fixture.run(seconds: 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.awakeMock.kicks == 0, "it already spoke first")
    }

    /// Their words are the better prompt, and a slow answer to them is what a cue would land on.
    @Test func aKickIsSpentOnceSomeoneHasSpokenPastTheQuestion() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.audio.onSpeechStarted?()
        fixture.audio.onPhraseFinished?("triage_ask")
        fixture.audio.onSpeechEnded?()
        try await fixture.settleInbox()
        fixture.run(seconds: 10)
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.awakeMock.kicks == 0)
        #expect(fixture.coordinator.aiQuiet, "the chip covers it, if the AI really did say nothing")
    }

    /// That may only be `triage_ask` coming back through the mic, and it mustn't cost the AI its first word.
    @Test func speechThatEndsDuringTheQuestionLeavesTheKick() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.audio.onSpeechStarted?()
        fixture.audio.onSpeechEnded?()
        fixture.audio.onPhraseFinished?("triage_ask")
        try await fixture.settleInbox()
        fixture.run(seconds: 3.8)
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.awakeMock.kicks == 0, "the AI may yet answer it")
        fixture.run(seconds: 0.4)
        try await waitUntil("the kick went up") { fixture.awakeMock.kicks == 1 }
    }

    @Test func aKickWithNoReplyShowsTheChip() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.audio.onPhraseFinished?("triage_ask")
        try await waitUntil("the kick went up") { fixture.awakeMock.kicks == 1 }
        fixture.run(seconds: 3.8)
        #expect(!fixture.coordinator.aiQuiet)
        fixture.run(seconds: 0.4)
        #expect(fixture.coordinator.aiQuiet)
    }

    @Test func aKickDoesNotHaveTheAIIntroduceItselfAgain() async throws {
        let fixture = try await connected()
        fixture.coordinator.force(stateID: "chest_wait")
        try await waitUntil("an awake socket opened") { fixture.awakeMock.requests.count == 1 }
        fixture.awakeMock.emit(.ready)
        try await waitUntil("the link came up") { fixture.coordinator.liveConnected }
        fixture.awakeMock.emit(.audio(chunk))
        try await waitUntil("it talked") { fixture.coordinator.state.modelTurnActive }
        fixture.awakeMock.emit(.turnComplete)
        try await waitUntil("the turn ended") { !fixture.coordinator.state.modelTurnActive }

        fixture.coordinator.perform(.notThis)
        #expect(fixture.coordinator.state.stateID == "triage")
        fixture.audio.onPhraseFinished?("triage_ask")
        try await fixture.settleInbox()
        fixture.run(seconds: 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.awakeMock.kicks == 0)
    }

    // MARK: - With no pack

    @Test func withNoPackTheSessionOnlyHearsAndNeverSpeaks() async throws {
        let bundle = try noPackBundle()
        let fixture = try await connected(bundle: bundle)
        try await intoTriage(fixture)

        #expect(!fixture.gate.modelAudioOpen)
        #expect(fixture.audio.lastPolicy?.modelSpeechOpen == false)
        #expect(fixture.audio.lastPolicy?.micUplink == true, "the ears stay on, so a report still lands")
        try await waitUntil("the seed went up") { !fixture.awakeMock.sentBriefs.isEmpty }
        #expect(fixture.awakeMock.sentBriefs[0].text.contains("you_may_speak=false"))

        fixture.audio.onPhraseFinished?("triage_ask")
        fixture.run(seconds: 5)
        try await fixture.settleInbox()
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.awakeMock.kicks == 0, "the prompt says don't speak, so nothing asks it to")

        fixture.awakeMock.emit(.audio(chunk))
        fixture.awakeMock.emit(.turnComplete)
        try await fixture.settleInbox()
        try await Task.sleep(for: .milliseconds(30))
        #expect(!fixture.audio.calls.contains(.modelAudio(chunk)))

        let version = fixture.coordinator.state.version
        fixture.awakeMock.emit(.functionCalls([reportFindingCall("chest_pain", version: version)]))
        try await waitUntil("a report still routes") { fixture.coordinator.state.stateID == "chest_call" }
    }

    /// A card's speech table can't know which session is up, and this one has no approved text.
    @Test func withNoPackACardKeepsTheAwakeSessionSilent() async throws {
        let fixture = try await connected(bundle: try noPackBundle())
        try await intoTriage(fixture)
        fixture.coordinator.perform(.emsArrived)
        #expect(fixture.coordinator.state.stateID == "handoff")
        #expect(fixture.coordinator.liveConnected)

        #expect(!fixture.gate.modelAudioOpen)
        #expect(fixture.audio.lastPolicy?.modelSpeechOpen == false)
        fixture.awakeMock.emit(.audio(chunk))
        fixture.awakeMock.emit(.turnComplete)
        try await fixture.settleInbox()
        try await Task.sleep(for: .milliseconds(30))
        #expect(!fixture.audio.calls.contains(.modelAudio(chunk)))
    }

    /// The engine's table has the card open, but nothing this session said was let through, so
    /// nothing gets corrected, and the session isn't told it may speak.
    @Test func withNoPackACardCorrectsNothingNobodyHeard() async throws {
        let fixture = try await connected(bundle: try noPackBundle())
        try await intoTriage(fixture)
        fixture.coordinator.perform(.emsArrived)
        #expect(fixture.coordinator.state.stateID == "handoff")
        try await waitUntil("the card's brief went up") { fixture.awakeMock.sentBriefs.last?.stateID == "handoff" }
        #expect(fixture.awakeMock.sentBriefs.last?.modelSpeechOpen == false)
        fixture.audio.clearCalls()

        fixture.awakeMock.emit(.outputTranscript("Check his pulse."))
        fixture.awakeMock.emit(.turnComplete)
        try await fixture.settleInbox()
        #expect(fixture.logDetails(.sentinelFlag) == ["pulse_check"], "it still goes on the record")
        #expect(fixture.audio.played.isEmpty)
    }

    /// The other side: the same card with the arrest session up talks as it always has, pack or no pack.
    @Test func withNoPackTheArrestSessionsVoiceIsUntouched() async throws {
        let fixture = try await connected(bundle: try noPackBundle())
        fixture.coordinator.force(stateID: "handoff")
        #expect(fixture.gate.modelAudioOpen)
        #expect(fixture.audio.lastPolicy?.modelSpeechOpen == true)
    }

    @Test func comingBackFromAnAwakeCardOpensTheArrestVoiceAgain() async throws {
        let fixture = try await connected(bundle: try noPackBundle())
        try await intoTriage(fixture)
        fixture.coordinator.perform(.emsArrived)
        #expect(!fixture.gate.modelAudioOpen)
        fixture.coordinator.force(stateID: "place_hands")
        #expect(fixture.gate.modelAudioOpen, "the policy goes up for the mode this state needs, not the one just left")
        #expect(fixture.audio.lastPolicy?.modelSpeechOpen == true)
    }

    @Test func withNoPackThereIsNoBeatToSeed() throws {
        let fixture = try Fixture(bundle: try noPackBundle())
        fixture.coordinator.beginRescue()
        fixture.coordinator.perform(.yes)
        #expect(!fixture.coordinator.canSeedBadLine)
    }

    // MARK: - The quiet chip

    @Test func quietForFourSecondsAfterSomeoneSpeaksShowsTheChip() async throws {
        let fixture = try await connected()
        let coordinator = fixture.coordinator
        try await intoTriage(fixture)
        fixture.audio.onSpeechStarted?()
        fixture.audio.onSpeechEnded?()
        try await fixture.settleInbox()

        fixture.run(seconds: 3.8)
        #expect(!coordinator.aiQuiet)
        fixture.run(seconds: 0.4)
        #expect(coordinator.aiQuiet)

        fixture.awakeMock.emit(.audio(chunk))
        try await waitUntil("the voice cleared it") { !coordinator.aiQuiet }
    }

    @Test func anAnswerInTimeShowsNoChip() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.audio.onSpeechEnded?()
        try await fixture.settleInbox()
        fixture.run(seconds: 2)
        fixture.awakeMock.emit(.audio(chunk))
        try await waitUntil("it answered") { fixture.coordinator.state.modelTurnActive }
        fixture.run(seconds: 5)
        #expect(!fixture.coordinator.aiQuiet)
    }

    @Test func speakingAgainStartsTheWaitOver() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.audio.onSpeechEnded?()
        try await fixture.settleInbox()
        fixture.run(seconds: 3)
        fixture.audio.onSpeechStarted?()
        try await fixture.settleInbox()
        fixture.run(seconds: 3)
        #expect(!fixture.coordinator.aiQuiet, "they're still talking")
    }

    /// The chip said to use the buttons with the AI audibly talking, and stayed after it finished.
    @Test func aNoiseWhileTheAIIsTalkingStartsNoWait() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.awakeMock.emit(.audio(chunk))
        try await waitUntil("it began") { fixture.coordinator.state.modelTurnActive }
        fixture.audio.onSpeechStarted?()
        fixture.audio.onSpeechEnded?()
        try await fixture.settleInbox()
        fixture.run(seconds: 5)
        #expect(!fixture.coordinator.aiQuiet)
        #expect(fixture.coordinator.state.modelTurnActive, "and the noise doesn't end its turn either")
    }

    /// Told something, it's meant to report and say nothing.
    @Test func aReportIsNotTheAIGoingQuiet() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.audio.onSpeechStarted?()
        fixture.audio.onSpeechEnded?()
        try await fixture.settleInbox()
        fixture.run(seconds: 2)
        let version = fixture.coordinator.state.version
        fixture.awakeMock.emit(.functionCalls([reportFindingCall("aspirin_unsafe", version: version)]))
        try await waitUntil("the report landed") { fixture.coordinator.modelCalls.count == 1 }
        #expect(fixture.coordinator.state.stateID == "triage")
        fixture.run(seconds: 5)
        #expect(!fixture.coordinator.aiQuiet)
    }

    @Test func aReportCalmsAChipAlreadyShowing() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.audio.onSpeechEnded?()
        try await fixture.settleInbox()
        fixture.run(seconds: 4.2)
        #expect(fixture.coordinator.aiQuiet)
        let version = fixture.coordinator.state.version
        fixture.awakeMock.emit(.functionCalls([reportFindingCall("aspirin_unsafe", version: version)]))
        try await waitUntil("the report cleared it") { !fixture.coordinator.aiQuiet }
    }

    @Test func aReportTheGateTurnedAwayIsStillSilence() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.audio.onSpeechEnded?()
        try await fixture.settleInbox()
        fixture.run(seconds: 2)
        let stale = fixture.coordinator.state.version - 1
        fixture.awakeMock.emit(.functionCalls([reportFindingCall("other_concern", version: stale)]))
        try await waitUntil("the report landed") { fixture.coordinator.modelCalls.count == 1 }
        #expect(fixture.logDetails(.proposalRejected).count == 1)
        fixture.run(seconds: 2.2)
        #expect(fixture.coordinator.aiQuiet)
    }

    /// An accepted say logs nothing, so the rejection before it is still the last entry.
    @Test func anAcceptedCallAfterARejectedOneStillStopsTheWait() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.audio.onSpeechEnded?()
        try await fixture.settleInbox()
        fixture.run(seconds: 1)
        let version = fixture.coordinator.state.version
        fixture.awakeMock.emit(.functionCalls([reportFindingCall("other_concern", version: version - 1)]))
        try await waitUntil("the stale report landed") { fixture.coordinator.modelCalls.count == 1 }
        let say = RealtimeFunctionCall(id: "call-2", name: "say", args: ["phrase_id": "assign_helper", "state_version": .number(Double(version))])
        fixture.awakeMock.emit(.functionCalls([say]))
        try await waitUntil("the say landed") { fixture.coordinator.modelCalls.count == 2 }
        #expect(fixture.audio.played.contains("assign_helper"))
        #expect(fixture.logDetails(.proposalRejected).count == 1)
        fixture.run(seconds: 4.2)
        #expect(!fixture.coordinator.aiQuiet)
    }

    @Test func someoneTalkingAgainTakesTheChipDown() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.audio.onSpeechEnded?()
        try await fixture.settleInbox()
        fixture.run(seconds: 4.2)
        #expect(fixture.coordinator.aiQuiet)
        fixture.audio.onSpeechStarted?()
        try await waitUntil("it came down") { !fixture.coordinator.aiQuiet }
    }

    @Test func aMoveToAClosedStepClearsTheChip() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.audio.onSpeechEnded?()
        try await fixture.settleInbox()
        fixture.run(seconds: 4.2)
        #expect(fixture.coordinator.aiQuiet)
        fixture.coordinator.perform(.triageChest)
        #expect(!fixture.coordinator.aiQuiet)
        fixture.audio.onSpeechEnded?()
        try await fixture.settleInbox()
        fixture.run(seconds: 5)
        #expect(!fixture.coordinator.aiQuiet, "the voice is closed here, so its silence means nothing")
    }

    @Test func noChipWhileTheLinkIsDown() async throws {
        let fixture = try await connected()
        fixture.coordinator.perform(.yes)
        fixture.audio.onSpeechEnded?()
        try await fixture.settleInbox()
        fixture.run(seconds: 5)
        #expect(!fixture.coordinator.aiQuiet, "the link chip is already saying so")
    }

    @Test func noChipOnTheArrestPath() async throws {
        let fixture = try await connected()
        #expect(fixture.gate.modelAudioOpen)
        fixture.audio.onSpeechEnded?()
        try await fixture.settleInbox()
        fixture.run(seconds: 5)
        #expect(!fixture.coordinator.aiQuiet)
    }

    // MARK: - Barge-in

    @Test func aChairScrapeDoesNotCutAnAwakeAnswer() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.audio.clearCalls()

        fixture.audio.onSpeechStarted?()
        #expect(!fixture.audio.calls.contains(.flush))
        #expect(fixture.gate.modelAudioOpen)

        fixture.awakeMock.emit(.audio(chunk))
        try await waitUntil("the answer kept playing") { fixture.audio.calls.contains(.modelAudio(chunk)) }

        fixture.awakeMock.emit(.interrupted)
        try await waitUntil("the server's word flushed it") { fixture.audio.calls.contains(.flush) }
    }

    /// Unchanged from the arrest path, where `talkingOverTheModelDropsTheRestOfItsAudio` pins it, and
    /// back in force after a swap.
    @Test func theArrestPathFlushesOnSpeechAgainAfterASwap() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.coordinator.perform(.patientUnresponsive)
        try await waitUntil("a new arrest socket opened") { fixture.mock.requests.count == 2 }
        fixture.audio.clearCalls()
        fixture.audio.onSpeechStarted?()
        #expect(fixture.audio.calls.contains(.flush))
        #expect(!fixture.gate.modelAudioOpen)
    }

    // MARK: - Frames

    @Test func anAwakeScanStartsNoBurstOfItsOwn() throws {
        let fixture = try Fixture(canLocate: true, bundle: try mergedBundle())
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.force(stateID: "chest_scan")
        #expect(coordinator.overlayTarget == .aedDevice)
        #expect(fixture.vision.bursts == 0)
        #expect(fixture.vision.locateCount == 1, "a locate isn't a frame for the model")
        #expect(fixture.audio.lastPolicy?.frameBurstsOnly == true)

        fixture.audio.onSpeechStarted?()
        #expect(fixture.vision.bursts == 1)
    }

    // MARK: - Re-asks

    private func talking(_ fixture: Fixture) async throws {
        fixture.awakeMock.emit(.audio(chunk))
        try await waitUntil("the turn began") { fixture.coordinator.state.modelTurnActive }
    }

    @Test func aReAskWaitsForTheAIToFinish() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        try await talking(fixture)

        fixture.run(seconds: 33)
        #expect(!fixture.audio.played.contains("triage_recheck"))

        fixture.awakeMock.emit(.turnComplete)
        try await waitUntil("the turn ended") { !fixture.coordinator.state.modelTurnActive }
        fixture.run(seconds: 0.2)
        #expect(fixture.audio.played.contains("triage_recheck"))
    }

    @Test func aReAskWaitsEightSecondsAtMost() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        try await talking(fixture)

        fixture.run(seconds: 37.6)
        #expect(!fixture.audio.played.contains("triage_recheck"))
        fixture.run(seconds: 0.6)
        #expect(fixture.audio.played.contains("triage_recheck"), "a turn that never ends can't hold it off")
    }

    @Test func aDroppedConnectionEndsTheTurnForTheReAsk() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        try await talking(fixture)
        fixture.awakeMock.emit(.closed(.networkFailure(code: nil)))
        try await waitUntil("the turn ended") { !fixture.coordinator.state.modelTurnActive }
        fixture.run(seconds: 30.2)
        #expect(fixture.audio.played.contains("triage_recheck"))
    }

    /// Said over someone talking, it would also take the place of the answer they're about to get.
    @Test func aReAskHoldsWhileSomeoneTalksAndForTheAnswerAfter() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.run(seconds: 28)
        fixture.audio.onSpeechStarted?()
        try await waitUntil("the hold began") { fixture.coordinator.state.modelTurnActive }
        fixture.run(seconds: 2.4)
        #expect(!fixture.audio.played.contains("triage_recheck"))

        fixture.audio.onSpeechEnded?()
        try await fixture.settleInbox()
        fixture.run(seconds: 3)
        #expect(!fixture.audio.played.contains("triage_recheck"), "the answer may still be coming")

        fixture.awakeMock.emit(.audio(chunk))
        try await fixture.settleInbox()
        fixture.run(seconds: 0.4)
        #expect(!fixture.audio.played.contains("triage_recheck"), "it came")
        fixture.awakeMock.emit(.turnComplete)
        try await waitUntil("the turn ended") { !fixture.coordinator.state.modelTurnActive }
        fixture.run(seconds: 0.2)
        #expect(fixture.audio.played.contains("triage_recheck"))
    }

    @Test func noAnswerEndsTheHoldWithTheWait() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.run(seconds: 28)
        fixture.audio.onSpeechStarted?()
        fixture.audio.onSpeechEnded?()
        try await fixture.settleInbox()
        fixture.run(seconds: 3.6)
        #expect(fixture.coordinator.state.modelTurnActive)
        #expect(!fixture.audio.played.contains("triage_recheck"))
        fixture.run(seconds: 0.8)
        #expect(!fixture.coordinator.state.modelTurnActive)
        #expect(fixture.audio.played.contains("triage_recheck"))
    }

    /// The server's interrupt ends the AI's turn while they're still talking over it.
    @Test func aReAskHoldsForSomeoneWhoTalkedOverTheAnswer() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.run(seconds: 26)
        try await talking(fixture)
        fixture.audio.onSpeechStarted?()
        try await cut(fixture)
        fixture.run(seconds: 5)
        #expect(!fixture.audio.played.contains("triage_recheck"), "they're still talking")
        #expect(fixture.coordinator.state.modelTurnActive)

        fixture.audio.onSpeechEnded?()
        try await fixture.settleInbox()
        fixture.run(seconds: 4.8)
        #expect(!fixture.coordinator.state.modelTurnActive, "no answer, so the wait is over")
        #expect(fixture.audio.played.contains("triage_recheck"))
    }

    /// Sends the interrupt with a marker behind it on the same path, so it has landed before the clock runs.
    private func cut(_ fixture: Fixture) async throws {
        fixture.awakeMock.emit(.interrupted)
        fixture.awakeMock.emit(.inputTranscript(" after-the-cut"))
        try await waitUntil("the cut landed") { fixture.coordinator.heardTranscript.contains("after-the-cut") }
    }

    /// The client VAD can close on a short "Sorry, what?" before the server's interrupt arrives.
    @Test func aReAskHoldsForAShortQuestionThatEndedBeforeTheCut() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.run(seconds: 28)
        try await talking(fixture)
        fixture.audio.onSpeechStarted?()
        fixture.audio.onSpeechEnded?()
        try await fixture.settleInbox()
        fixture.run(seconds: 0.4)
        try await cut(fixture)
        fixture.run(seconds: 3.2)
        #expect(!fixture.audio.played.contains("triage_recheck"), "the answer to them may still be coming")
        #expect(fixture.coordinator.state.modelTurnActive)
        #expect(!fixture.coordinator.aiQuiet)

        fixture.run(seconds: 0.8)
        #expect(fixture.coordinator.aiQuiet, "4 s from when they stopped")
        #expect(!fixture.coordinator.state.modelTurnActive)
        #expect(fixture.audio.played.contains("triage_recheck"))
    }

    /// Speech that ended well before the cut is a question the AI was already answering.
    @Test func aCutLongAfterSpeechHoldsNothing() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.run(seconds: 26)
        try await talking(fixture)
        fixture.audio.onSpeechStarted?()
        fixture.audio.onSpeechEnded?()
        try await fixture.settleInbox()
        fixture.run(seconds: 2)
        try await cut(fixture)
        #expect(!fixture.coordinator.state.modelTurnActive)
        fixture.run(seconds: 2.2)
        #expect(fixture.audio.played.contains("triage_recheck"))
        #expect(!fixture.coordinator.aiQuiet)
    }

    @Test func someoneTalkingHoldsAReAskEightSecondsAtMost() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.run(seconds: 29)
        fixture.audio.onSpeechStarted?()
        try await waitUntil("the hold began") { fixture.coordinator.state.modelTurnActive }
        fixture.run(seconds: 8.4)
        #expect(!fixture.audio.played.contains("triage_recheck"))
        fixture.run(seconds: 0.8)
        #expect(fixture.audio.played.contains("triage_recheck"))
    }

    /// The AI's turn is its own to end, and a person talking over it doesn't take that over.
    @Test func aPersonTalkingOverTheAIDoesNotEndItsTurnEarly() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        try await talking(fixture)
        fixture.audio.onSpeechStarted?()
        fixture.audio.onSpeechEnded?()
        try await fixture.settleInbox()
        fixture.run(seconds: 6)
        #expect(fixture.coordinator.state.modelTurnActive)
    }

    @Test func aClosedVoiceHoldsNothingForSomeoneTalking() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.coordinator.setDispatcher(open: true)
        fixture.audio.onSpeechStarted?()
        try await fixture.settleInbox()
        #expect(!fixture.coordinator.state.modelTurnActive)
    }

    /// Audio the gate turned away was heard by nobody, so there's nothing to wait for.
    @Test func modelAudioThatIsNotPlayedHoldsNothing() async throws {
        let fixture = try await connected()
        try await intoTriage(fixture)
        fixture.coordinator.setDispatcher(open: true)
        fixture.awakeMock.emit(.audio(chunk))
        fixture.awakeMock.emit(.turnComplete)
        try await waitUntil("the turn ended") { fixture.audio.calls.contains(.turnEnded) }
        try await fixture.settleInbox()
        #expect(!fixture.coordinator.state.modelTurnActive)
    }

    // MARK: - The seeded beat

    @Test func theSeededAwakeLineGoesThroughTheRealPathAndIsCorrected() throws {
        let fixture = try Fixture(bundle: try mergedBundle())
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.yes)
        fixture.audio.clearCalls()

        #expect(coordinator.canSeedBadLine)
        coordinator.seedBadLine()

        #expect(fixture.audio.played == [AppCoordinator.seededAwakePhraseID, "correct_diagnosis"])
        let flag = try #require(coordinator.log.entries.last { $0.kind == .sentinelFlag })
        #expect(flag.detail == "diagnosis")
        #expect(coordinator.seededSequences.contains(flag.seq))
        #expect(coordinator.operatorUsed)
        #expect(coordinator.saidTranscript.contains("[SEEDED]"))
        #expect(coordinator.state.stateID == "triage")
    }

    @Test func theSeededAwakeLineIsOnlyAvailableWhereTheAICanTalk() throws {
        let fixture = try Fixture(bundle: try mergedBundle())
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        #expect(!coordinator.canSeedBadLine)
        coordinator.perform(.yes)
        #expect(coordinator.canSeedBadLine)
        coordinator.perform(.triageChest)
        #expect(coordinator.state.stateID == "chest_call")
        #expect(!coordinator.canSeedBadLine, "the voice is closed on this step")
    }

    @Test func handPlacementStillSeedsTheArrestLine() throws {
        let fixture = try Fixture(bundle: try mergedBundle())
        fixture.coordinator.beginRescue()
        fixture.coordinator.force(stateID: "place_hands")
        fixture.audio.clearCalls()
        fixture.coordinator.seedBadLine()
        #expect(fixture.audio.played == [AppCoordinator.seededPhraseID, "correct_pulse"])
    }

    @Test func theSeededAwakeLineIsNotReportedToTheModelAsProtocolSpeech() async throws {
        let fixture = try Fixture(bundle: try mergedBundle())
        fixture.coordinator.beginRescue()
        fixture.audio.onPhraseFinished?(AppCoordinator.seededAwakePhraseID)
        try await fixture.settleInbox()
        #expect(!fixture.logDetails(.phrasePlayed).contains(AppCoordinator.seededAwakePhraseID))
    }
}
