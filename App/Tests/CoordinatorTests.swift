import CoreLocation
import Foundation
@testable import HealthAISim
import RescueAudio
@testable import RescueCore
import RescueLive
import RescueVision
import Synchronization
import Testing

@MainActor
@Suite struct OfflineTests {
    @Test func theFullFlowRunsWithNoModelNoPermissionsAndNoAR() throws {
        let fixture = try Fixture()
        let coordinator = fixture.coordinator
        coordinator.beginRescue()

        #expect(coordinator.state.stateID == "intake_responsive")
        #expect(coordinator.linkLabel == "Offline protocol")
        #expect(coordinator.showsCamera == false)
        #expect(fixture.vision.startCount == 0)
        #expect(fixture.audio.played == ["ask_responsive"])
        #expect(coordinator.instruction == coordinator.engine.bundle.text(forPhrase: "ask_responsive"))

        // Nobody answers. The question says itself again and waits; only the rescuer moves it on.
        fixture.run(seconds: 30.2)
        #expect(coordinator.state.stateID == "intake_responsive")
        #expect(fixture.audio.played == ["ask_responsive", "ask_responsive", "ask_responsive", "ask_responsive"])
        #expect(fixture.audio.metronome.isEmpty)
        coordinator.perform(.no)
        coordinator.perform(.no)
        #expect(coordinator.state.stateID == "position_patient")

        // From there every required step still plays, one tap each, and it ends up compressing.
        coordinator.perform(.called)
        coordinator.perform(.done)
        coordinator.perform(.done)
        #expect(coordinator.state.stateID == "compressions")
        #expect(fixture.audio.played.suffix(3) == ["roll_flat", "hands_center", "start_compressions"])
        #expect(fixture.audio.metronome == [true])
        #expect(coordinator.showsPulse)

        coordinator.perform(.aedHere)
        coordinator.perform(.done)
        coordinator.perform(.padsOn)
        #expect(coordinator.state.stateID == "aed_analyze")
        #expect(fixture.audio.metronome == [true, false])
        #expect(coordinator.showsPulse == false, "The pulse would invite contact during AED analysis")

        coordinator.perform(.aedSaysCpr)
        #expect(coordinator.state.stateID == "compressions_aed")
        #expect(coordinator.showsPulse, "The rescuer is compressing, whether or not the phone clicks")

        coordinator.perform(.emsArrived)
        #expect(coordinator.isHandoff)
        let card = coordinator.handoffCard
        #expect(card.items.first { $0.label == "Pads on" }?.value != "not recorded")
        #expect(card.items.first { $0.label == "Shocks marked" }?.value == "not recorded")
    }

    @Test func withNoModelTheMicIsNeverOpened() throws {
        let fixture = try Fixture()
        fixture.coordinator.beginRescue()
        #expect(fixture.audio.lastPolicy?.audioMode == .playbackOnly)
    }

    @Test func missingARNeverGatesAStep() throws {
        let fixture = try Fixture(arSupported: false)
        fixture.coordinator.beginRescue()
        fixture.coordinator.force(stateID: "place_hands")
        fixture.run(seconds: 5.2)
        fixture.coordinator.perform(.done)
        #expect(fixture.coordinator.state.stateID == "compressions")
    }

    @Test func noCameraPermissionMeansARNeverStartsSoItCannotPrompt() throws {
        let fixture = try Fixture(arSupported: true, cameraAllowed: false)
        fixture.coordinator.beginRescue()
        #expect(fixture.vision.startCount == 0)
        #expect(fixture.coordinator.showsCamera == false)
    }

    @Test func cameraPermissionStartsAR() throws {
        let fixture = try Fixture(arSupported: true, cameraAllowed: true)
        fixture.coordinator.beginRescue()
        #expect(fixture.vision.startCount == 1)
        #expect(fixture.coordinator.showsCamera)
    }

    @Test func beginningTwiceDoesNotReplayTheFirstStep() throws {
        let fixture = try Fixture()
        fixture.coordinator.beginRescue()
        fixture.coordinator.beginRescue()
        #expect(fixture.audio.played == ["ask_responsive"])
    }
}

@MainActor
@Suite struct EffectTests {
    @Test func phraseFinishedReachesTheEngineAndTheNextBrief() async throws {
        let fixture = try Fixture()
        fixture.coordinator.beginRescue()
        fixture.audio.onPhraseFinished?("ask_responsive")
        try await waitUntil("the phrase was recorded") { fixture.coordinator.state.recentlyPlayed == ["ask_responsive"] }
        #expect(fixture.logDetails(.phrasePlayed) == ["ask_responsive"])
    }

    @Test func aKeywordPausesAudioAndTheTickResumesIt() throws {
        let fixture = try Fixture()
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.startCpr)
        coordinator.seedKeyword(.aedTalking)
        #expect(fixture.audio.calls.contains(.pause(8)))
        #expect(coordinator.state.stateID == "compressions")
        fixture.run(seconds: 8.4)
        #expect(fixture.audio.calls.contains(.resume))
    }

    @Test func everyEffectIsForwardedToVision() throws {
        let fixture = try Fixture()
        fixture.coordinator.beginRescue()
        fixture.coordinator.force(stateID: "place_hands")
        #expect(fixture.vision.applied.contains(.overlay(.chestCenter)))
        #expect(fixture.coordinator.overlayTarget == .chestCenter)
        #expect(fixture.vision.applied.contains { if case .policyChanged = $0 { true } else { false } })
    }

    @Test func aCallPutsAudioInPlaybackOnly() async throws {
        let fixture = try Fixture(live: true)
        try await fixture.beginAndConnect()
        fixture.audio.onCallChanged?(true)
        try await waitUntil("the call was noticed") { fixture.coordinator.state.callActive }
        #expect(fixture.audio.lastPolicy?.audioMode == .playbackOnly)
        #expect(fixture.audio.lastPolicy?.micUplink == false)
    }

    @Test func aDropOrCutReachesTheAudioBeforeTheNextPhrase() throws {
        let fixture = try Fixture()
        fixture.coordinator.beginRescue()
        fixture.coordinator.perform(.startCpr)
        fixture.coordinator.perform(.aedHere)
        fixture.audio.clearCalls()

        fixture.coordinator.perform(.done)
        let drop = try #require(fixture.audio.calls.firstIndex(of: .dropQueued(["call_911", "calling_911"])))
        let pads = try #require(fixture.audio.calls.firstIndex(of: .play("pads_place")))
        #expect(drop < pads)

        fixture.audio.clearCalls()
        fixture.coordinator.perform(.padsOn)
        let cut = try #require(fixture.audio.calls.firstIndex(of: .cut))
        let authority = try #require(fixture.audio.calls.firstIndex(of: .play("aed_authority")))
        #expect(cut < authority)
    }

    @Test func noTouchPlaysEveryRequiredStepWithoutADrop() throws {
        let fixture = try Fixture()
        fixture.coordinator.beginRescue()
        fixture.audio.clearCalls()
        fixture.run(seconds: 26)
        #expect(!fixture.audio.calls.contains { if case .dropQueued = $0 { true } else { $0 == .cut } })
    }

    @Test func theAEDTalkingQuietsTheAudioAndThePulseAndItsChipSaysSo() throws {
        let fixture = try Fixture()
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.startCpr)
        coordinator.perform(.aedHere)
        coordinator.perform(.done)
        #expect(coordinator.state.stateID == "pads")
        #expect(coordinator.showsPulse)

        // Eval row 18, in the case from the review: pads on, the Pads on tap missed.
        coordinator.dispatch(.model(ModelProposal(
            action: .reportFinding(.aedPrompting, source: .heard, confidence: .high),
            stateVersion: coordinator.state.version,
            issuedAt: fixture.clock.now
        )))
        #expect(fixture.audio.calls.contains(.pause(8)))
        #expect(coordinator.aedTalking)
        #expect(!coordinator.showsPulse, "PUSH would contradict a stand clear")
        #expect(coordinator.state.stateID == "pads")
        #expect(!fixture.audio.metronome.contains(false))

        fixture.run(seconds: 8.2)
        #expect(fixture.audio.calls.contains(.resume))
        #expect(!coordinator.aedTalking)
        #expect(coordinator.showsPulse)
    }

    @Test func aDispatcherKeywordClosesTheMicEverywhereAndItReopens() throws {
        let fixture = try Fixture()
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        #expect(fixture.gate.micOpen)
        coordinator.dispatch(.keyword(.dispatcherTalking))
        #expect(!fixture.gate.micOpen)
        #expect(fixture.audio.lastPolicy?.micUplink == false)
        #expect(coordinator.micClosedForDispatcher)
        fixture.clock.advance(31)
        coordinator.tick()
        #expect(fixture.gate.micOpen)
        #expect(fixture.audio.lastPolicy?.micUplink == true)
        #expect(!coordinator.micClosedForDispatcher)
    }

    @Test func aCallPromptAndAStepTogetherBothStayOnScreen() throws {
        let fixture = try Fixture()
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.startCpr)
        let text = try #require(coordinator.prompt?.text)
        #expect(text.contains("Calling 911"))
        #expect(text.contains("Heel of one hand"))
        #expect(coordinator.instruction == coordinator.engine.bundle.text(forPhrase: "start_compressions"))
    }

    @Test func aVoiceFailureClearsOnceAPhrasePlaysAgain() async throws {
        let fixture = try Fixture()
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        fixture.audio.onStatus?(.running(.playbackOnly))
        fixture.audio.onStatus?(.readAloudFailed)
        try await waitUntil("the failure shows") { coordinator.audioHealth == .voiceFailed }
        fixture.audio.onPhraseFinished?("ask_responsive")
        try await waitUntil("the failure clears") { coordinator.audioHealth == .ok }
    }

    @Test func promptsExpireButTheInstructionStays() throws {
        let fixture = try Fixture()
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.startCpr)
        fixture.run(seconds: 60.2)
        #expect(coordinator.prompt?.text == coordinator.engine.bundle.text(forPhrase: "push_hard"))
        fixture.run(seconds: 8.2)
        #expect(coordinator.prompt == nil)
        #expect(coordinator.instruction == coordinator.engine.bundle.text(forPhrase: "start_compressions"))
    }

    @Test func aStateWithNoPhraseKeepsShowingTheLastOne() throws {
        let fixture = try Fixture()
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.startCpr)
        coordinator.perform(.scan)
        #expect(coordinator.state.stateID == "resource_scan")
        #expect(coordinator.instruction == coordinator.engine.bundle.text(forPhrase: "start_compressions"))
    }
}

@MainActor
@Suite struct LiveWiringTests {
    private let chunk = Data([1, 2, 3, 4])
    private let marker = Data([9, 9, 9, 9])

    @Test func proposalsGoThroughTheEngine() async throws {
        let fixture = try Fixture(live: true)
        try await fixture.beginAndConnect()
        #expect(fixture.coordinator.linkLabel == "Live")
        let version = fixture.coordinator.state.version
        fixture.mock.emit(.functionCalls([reportFindingCall("not_breathing", version: version)]))
        try await waitUntil("the proposal moved the state") { fixture.coordinator.state.stateID == "position_patient" }
        #expect(fixture.logDetails(.finding) == ["not_breathing"])
        #expect(fixture.coordinator.modelCalls.count == 1)
    }

    @Test func aModelReportCannotLeaveCPR() async throws {
        let fixture = try Fixture(live: true)
        try await fixture.beginAndConnect()
        fixture.coordinator.perform(.startCpr)
        let version = fixture.coordinator.state.version
        fixture.mock.emit(.functionCalls([reportFindingCall("breathing_normally", version: version)]))
        try await waitUntil("the proposal was rejected") { !fixture.logDetails(.proposalRejected).isEmpty }
        #expect(fixture.coordinator.state.stateID == "compressions")
        #expect(fixture.audio.metronome == [true])
    }

    @Test func micAudioFollowsThePolicyOnEverySend() async throws {
        let fixture = try Fixture(live: true)
        try await fixture.beginAndConnect()
        let send = try #require(fixture.audio.onUplinkPCM)

        send(chunk)
        try await waitUntil("audio went up") { fixture.mock.sentAudio == [self.chunk] }

        fixture.coordinator.setDispatcher(open: true)
        send(Data([7, 7]))

        fixture.coordinator.setDispatcher(open: false)
        send(marker)
        try await waitUntil("the marker went up") { fixture.mock.sentAudio.contains(self.marker) }
        #expect(fixture.mock.sentAudio == [chunk, marker], "Nothing may go up while a dispatcher may be audible")
    }

    @Test func framesFollowThePolicyOnEverySend() async throws {
        let fixture = try Fixture(live: true)
        try await fixture.beginAndConnect()

        fixture.vision.emitFrame(chunk)
        try await waitUntil("a frame went up in an open state") { fixture.mock.sentFrames == [self.chunk] }

        fixture.coordinator.force(stateID: "pads")
        #expect(fixture.gate.framesOpen == false)
        fixture.vision.emitFrame(Data([7, 7]))
        // Time for the pump to reach that frame while the gate is still closed.
        try await Task.sleep(for: .milliseconds(100))
        fixture.coordinator.force(stateID: "resource_scan")
        fixture.vision.emitFrame(marker)
        try await waitUntil("a frame went up after reopening") { fixture.mock.sentFrames.contains(self.marker) }
        #expect(!fixture.mock.sentFrames.contains(Data([7, 7])), "No frame uplink during pads")
    }

    @Test func modelAudioIsGatedByPolicy() async throws {
        let fixture = try Fixture(live: true)
        try await fixture.beginAndConnect()

        fixture.mock.emit(.audio(chunk))
        try await waitUntil("audio played in an open state") { fixture.audio.calls.contains(.modelAudio(self.chunk)) }

        fixture.coordinator.perform(.startCpr)
        fixture.mock.emit(.audio(Data([7, 7])))
        fixture.mock.emit(.turnComplete)
        try await waitUntil("the turn ended") { fixture.audio.calls.contains(.turnEnded) }
        #expect(!fixture.audio.calls.contains(.modelAudio(Data([7, 7]))), "No model audio in closed states")
    }

    @Test func talkingOverTheModelDropsTheRestOfItsAudio() async throws {
        let fixture = try Fixture(live: true)
        try await fixture.beginAndConnect()

        fixture.audio.onSpeechStarted?()
        #expect(fixture.audio.calls.contains(.flush))
        #expect(fixture.vision.bursts == 1)

        fixture.mock.emit(.audio(Data([7, 7])))
        fixture.mock.emit(.interrupted)
        try await waitUntil("the turn ended") { fixture.audio.calls.contains(.turnEnded) }
        #expect(!fixture.audio.calls.contains(.modelAudio(Data([7, 7]))))

        fixture.mock.emit(.audio(marker))
        try await waitUntil("the next turn plays") { fixture.audio.calls.contains(.modelAudio(self.marker)) }
    }

    @Test func speechEndTellsTheServer() async throws {
        let fixture = try Fixture(live: true)
        try await fixture.beginAndConnect()
        fixture.audio.onSpeechEnded?()
        try await waitUntil("stream end went up") { fixture.mock.sent.contains(.audioStreamEnd) }
    }

    @Test func aBadLineIsFlaggedAndCorrected() async throws {
        let fixture = try Fixture(live: true)
        try await fixture.beginAndConnect()
        fixture.mock.emit(.outputTranscript("You should check "))
        fixture.mock.emit(.outputTranscript("his pulse first."))
        try await waitUntil("the correction played") { fixture.audio.played.contains("correct_pulse") }
        #expect(fixture.logDetails(.sentinelFlag) == ["pulse_check"])
        #expect(fixture.gate.modelAudioOpen == false, "The engine holds model speech after a flag")
        #expect(fixture.coordinator.state.stateID == "intake_responsive", "A flag never changes the step")
    }

    @Test func theAuditorFlagsAfterTheTurnEnds() async throws {
        let auditor = Auditor(apiKey: APIKey("test"), http: auditorHTTP(category: "reassurance"))
        let fixture = try Fixture(live: true, auditor: auditor)
        try await fixture.beginAndConnect()
        // A line the validators can't catch, so only the auditor can flag it.
        fixture.mock.emit(.outputTranscript("It all sounded good to me."))
        fixture.mock.emit(.turnComplete)
        try await waitUntil("the auditor's flag landed") { fixture.logDetails(.sentinelFlag) == ["reassurance"] }
        #expect(fixture.audio.played.contains("correct_reassure"))
    }

    @Test func theAuditorDoesNotCorrectWhatTheValidatorAlreadyDid() async throws {
        let auditor = Auditor(apiKey: APIKey("test"), http: auditorHTTP(category: "pulse_check"))
        let fixture = try Fixture(live: true, auditor: auditor)
        try await fixture.beginAndConnect()
        fixture.mock.emit(.outputTranscript("Check his pulse."))
        fixture.mock.emit(.turnComplete)
        try await waitUntil("the validator flagged") { fixture.logDetails(.sentinelFlag) == ["pulse_check"] }
        // Long enough for the stubbed auditor to answer.
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.logDetails(.sentinelFlag) == ["pulse_check"])
    }

    @Test func aDeadAuditorChangesNothing() async throws {
        let dead: HTTPClient = { _ in throw URLError(.notConnectedToInternet) }
        let fixture = try Fixture(live: true, auditor: Auditor(apiKey: APIKey("test"), http: dead))
        try await fixture.beginAndConnect()
        let before = fixture.coordinator.state.stateID
        fixture.mock.emit(.outputTranscript("A harmless sentence."))
        fixture.mock.emit(.turnComplete)
        try await waitUntil("the turn ended") { fixture.audio.calls.contains(.turnEnded) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.logDetails(.sentinelFlag).isEmpty)
        #expect(fixture.coordinator.state.stateID == before)
    }

    /// The 911 agent is a scripted log, never a call. It starts by itself as the CPR path begins, shows
    /// on screen as calling, and can't move the rescue on.
    @Test func theCallerAgentStartsByItselfAndMovesNothing() throws {
        let fixture = try Fixture()
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        #expect(coordinator.callerAgentStatus == .idle)
        coordinator.perform(.no)
        coordinator.perform(.no)
        #expect(coordinator.state.stateID == "position_patient", "no call step to stop at")
        #expect(coordinator.callerAgentStatus == .calling, "it calls without being asked")
        #expect(fixture.audio.played.contains("calling_911"), "said once on the way")
        let lines = AppCoordinator.callerAgentLines(coordinator.callerScript)
        #expect(lines.first?.contains("Simulation, no real call") == true)
        #expect(lines.contains { $0.contains(coordinator.callerScript.situation) })
        #expect(!lines.contains { $0.contains("Tap Called") }, "nothing to tap")
        fixture.run(seconds: 30)
        #expect(coordinator.state.stateID == "position_patient", "the agent's call moves no step")
    }

    /// A choking patient who can't cough or speak gets the same background call, and the agent says
    /// what the rescuer is doing instead of CPR.
    @Test func theCallerAgentCallsForSevereChoking() throws {
        let fixture = try Fixture(bundle: try mergedBundle())
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.yes)
        coordinator.perform(.triageChoking)
        #expect(coordinator.state.stateID == "choke_check")
        #expect(coordinator.callerAgentStatus == .idle, "no call before the answer")
        fixture.clock.advance(1)
        coordinator.perform(.no)
        #expect(coordinator.state.stateID == "choke_back_blows")
        #expect(coordinator.callerAgentStatus == .calling)
        #expect(fixture.audio.played.contains("choke_calling"))
        let lines = AppCoordinator.callerAgentLines(coordinator.callerScript, choking: true)
        #expect(lines.contains { $0.contains("back blows and abdominal thrusts") })
        #expect(!lines.contains { $0.contains("CPR") })
    }

    /// Start CPR skips setup, and the call still starts.
    @Test func startCprStartsTheCallerAgentToo() throws {
        let fixture = try Fixture()
        fixture.coordinator.beginRescue()
        fixture.coordinator.perform(.startCpr)
        #expect(fixture.coordinator.callerAgentStatus == .calling)
    }

    /// "Calling 911 for you" is said, never shown as the step's instruction.
    @Test func theCallIsNeverTheInstruction() throws {
        let fixture = try Fixture()
        fixture.coordinator.beginRescue()
        fixture.coordinator.perform(.unsure)
        #expect(fixture.coordinator.instruction == fixture.coordinator.engine.bundle.text(forPhrase: "roll_flat"))
    }

    @Test func losingLiveSilentlyFallsBackToTheLocalProtocol() async throws {
        let fixture = try Fixture(live: true)
        try await fixture.beginAndConnect()
        fixture.mock.emit(.closed(.networkFailure(code: nil)))
        try await waitUntil("the link went down") { !fixture.coordinator.liveConnected }
        #expect(fixture.coordinator.linkLabel == "Offline protocol")
        fixture.coordinator.perform(.no)
        fixture.coordinator.perform(.no)
        #expect(fixture.coordinator.state.stateID == "position_patient")
        fixture.coordinator.perform(.startCpr)
        #expect(fixture.coordinator.state.stateID == "compressions")
        #expect(fixture.audio.played.contains("start_compressions"))
    }

    /// Reproduces the review's probe. With no turnComplete, the buffer would remember the category
    /// and the same bad line after a reconnect would go uncorrected.
    @Test func aDroppedConnectionEndsTheTurnForTheValidators() async throws {
        let fixture = try Fixture(live: true)
        try await fixture.beginAndConnect()
        fixture.mock.emit(.outputTranscript("Check his pulse."))
        try await waitUntil("the first flag") { fixture.logDetails(.sentinelFlag).count == 1 }
        #expect(fixture.audio.played.filter { $0 == "correct_pulse" }.count == 1)

        fixture.audio.onSpeechStarted?()
        fixture.mock.emit(.closed(.networkFailure(code: nil)))
        try await waitUntil("the link went down") { !fixture.coordinator.liveConnected }
        #expect(fixture.audio.calls.contains(.turnEnded))

        // Past the hold and the correction's cooldown.
        fixture.clock.advance(21)
        fixture.coordinator.tick()
        try await waitUntil("a new connection") { fixture.mock.requests.count == 2 }
        fixture.mock.emit(.ready)
        try await waitUntil("the link came back") { fixture.coordinator.liveConnected }

        fixture.mock.emit(.outputTranscript("Now check his pulse again."))
        try await waitUntil("the second flag") { fixture.logDetails(.sentinelFlag).count == 2 }
        #expect(fixture.audio.played.filter { $0 == "correct_pulse" }.count == 2)
    }

    /// The auditor can answer seconds later, and the rescue may have started over by then.
    @Test func anAuditorAnswerFromTheLastRescueIsIgnored() async throws {
        let answer = auditorHTTP(category: "reassurance")
        let slow: HTTPClient = { request in
            try? await Task.sleep(for: .milliseconds(150))
            return try await answer(request)
        }
        let fixture = try Fixture(live: true, auditor: Auditor(apiKey: APIKey("test"), http: slow))
        try await fixture.beginAndConnect()
        fixture.mock.emit(.outputTranscript("It all sounded good to me."))
        fixture.mock.emit(.turnComplete)
        try await waitUntil("the turn ended") { fixture.audio.calls.contains(.turnEnded) }

        fixture.coordinator.restartRescue()
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.logDetails(.sentinelFlag).isEmpty)
        #expect(!fixture.audio.played.contains("correct_reassure"))
    }

    /// The stale-session half of "check on every send": the gate has closed, but the session hasn't
    /// been told, so only the sender's own check stands between this audio and the network.
    @Test func theUplinkWorkerChecksTheGateItself() async throws {
        let fixture = try Fixture(live: true)
        try await fixture.beginAndConnect()
        let open = RuntimePolicy(modelSpeechOpen: true, micUplink: true, frameUplink: true, audioMode: .full)
        let closed = RuntimePolicy(modelSpeechOpen: false, micUplink: false, frameUplink: false, audioMode: .full)
        await fixture.settleSessionPolicy(open)

        fixture.gate.setPolicy(closed)
        fixture.gate.send(.audio(Data([7, 7])))
        fixture.gate.send(.audioEnd)
        fixture.gate.send(.frame(Data([8, 8])))
        // Time for the worker to reach those while the gate is still closed.
        try await Task.sleep(for: .milliseconds(100))

        fixture.gate.setPolicy(open)
        fixture.gate.send(.audio(marker))
        fixture.gate.send(.frame(chunk))
        try await waitUntil("the markers went up") {
            fixture.mock.sentAudio.contains(self.marker) && fixture.mock.sentFrames.contains(self.chunk)
        }
        #expect(!fixture.mock.sentAudio.contains(Data([7, 7])))
        #expect(!fixture.mock.sentFrames.contains(Data([8, 8])))
        #expect(!fixture.mock.sent.contains(.audioStreamEnd))
    }

    @Test func aMicProblemShowsWhileLiveLooksConnected() async throws {
        let fixture = try Fixture(live: true)
        let coordinator = fixture.coordinator
        try await fixture.beginAndConnect()
        #expect(!coordinator.aiCannotHear)

        fixture.audio.onStatus?(.micUnavailable(reason: "Voice processing gave no audio"))
        try await waitUntil("the problem shows") { coordinator.aiCannotHear }
        #expect(coordinator.linkLabel == "Live")

        // Playback running doesn't mean the mic came back.
        fixture.audio.onStatus?(.running(.playbackOnly))
        try await Task.sleep(for: .milliseconds(30))
        #expect(coordinator.aiCannotHear)

        fixture.audio.onStatus?(.running(.full))
        try await waitUntil("the problem clears") { !coordinator.aiCannotHear }
    }

    @Test func theFirstConnectionIsSeededWithTheFirstBrief() async throws {
        let fixture = try Fixture(live: true)
        try await fixture.beginAndConnect()
        #expect(fixture.mock.requests.first?.seedsHistory == true)
        try await waitUntil("the first brief went up") { !fixture.mock.sentBriefs.isEmpty }
        #expect(fixture.mock.sentBriefs.first?.stateID == "intake_responsive")
    }

    @Test func restartingRemembersACallInProgress() async throws {
        let fixture = try Fixture(live: true)
        try await fixture.beginAndConnect()
        fixture.audio.onCallChanged?(true)
        try await waitUntil("the call was noticed") { fixture.coordinator.state.callActive }
        fixture.coordinator.restartRescue()
        #expect(fixture.coordinator.state.callActive)
        #expect(fixture.gate.micOpen == false)
    }

    @Test func restartingUsesANewSession() async throws {
        let fixture = try Fixture(live: true)
        try await fixture.beginAndConnect()
        fixture.coordinator.perform(.startCpr)
        fixture.coordinator.restartRescue()
        try await waitUntil("a second connection opened") { fixture.mock.requests.count == 2 }
        #expect(fixture.mock.requests.last?.resumeHandle == nil)
        #expect(fixture.coordinator.state.stateID == "intake_responsive")
        #expect(fixture.audio.metronome.last == false)
        #expect(fixture.coordinator.log.entries.first?.kind == .sessionStarted)
        #expect(fixture.logDetails(.stateEntered) == ["intake_responsive"])
    }
}

@MainActor
@Suite struct SeededBeatTests {
    @Test func theBadLineGoesThroughTheRealPathAndTheCorrectionFollowsIt() throws {
        let fixture = try Fixture()
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.force(stateID: "place_hands")
        fixture.audio.clearCalls()

        #expect(coordinator.canSeedBadLine)
        coordinator.seedBadLine()

        #expect(fixture.audio.played == [AppCoordinator.seededPhraseID, "correct_pulse"])
        let flag = try #require(coordinator.log.entries.last { $0.kind == .sentinelFlag })
        #expect(flag.detail == "pulse_check")
        #expect(coordinator.seededSequences.contains(flag.seq))
        #expect(coordinator.operatorUsed)
        #expect(coordinator.saidTranscript.contains("[SEEDED]"))
        #expect(coordinator.state.stateID == "place_hands")
    }

    @Test func theBadLineIsOnlyAvailableDuringHandPlacement() throws {
        let fixture = try Fixture()
        fixture.coordinator.beginRescue()
        #expect(!fixture.coordinator.canSeedBadLine)
        fixture.coordinator.seedBadLine()
        #expect(!fixture.audio.played.contains(AppCoordinator.seededPhraseID))
        #expect(fixture.logDetails(.sentinelFlag).isEmpty)
    }

    @Test func theSeededLineIsNotReportedToTheModelAsProtocolSpeech() async throws {
        let fixture = try Fixture()
        fixture.coordinator.beginRescue()
        fixture.audio.onPhraseFinished?(AppCoordinator.seededPhraseID)
        fixture.audio.onPhraseFinished?("ask_responsive")
        try await waitUntil("the marker phrase was recorded") { !fixture.logDetails(.phrasePlayed).isEmpty }
        #expect(fixture.logDetails(.phrasePlayed) == ["ask_responsive"])
    }

    @Test func theStopReportIsARealProposalAndIsRejected() throws {
        let fixture = try Fixture()
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.startCpr)
        fixture.audio.clearCalls()

        coordinator.seedStopReport()

        let rejected = try #require(coordinator.log.entries.last { $0.kind == .proposalRejected })
        #expect(rejected.detail.contains("breathing_normally"))
        #expect(rejected.detail.contains("cannot_lower_urgency"))
        #expect(coordinator.seededSequences.contains(rejected.seq))
        #expect(coordinator.modelCalls.last?.seeded == true)
        #expect(coordinator.state.stateID == "compressions")
        #expect(!fixture.audio.metronome.contains(false), "Only a human action leaves CPR")
    }
}

@MainActor
@Suite struct DispatcherTests {
    @Test func openingAndClosingTellTheEngineAndThePolicyFollows() throws {
        let fixture = try Fixture()
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.setDispatcher(open: true)
        #expect(coordinator.state.dispatcherActive)
        #expect(fixture.gate.micOpen == false)
        #expect(fixture.gate.modelAudioOpen == false)
        #expect(fixture.audio.lastPolicy?.modelSpeechOpen == false)
        coordinator.setDispatcher(open: false)
        #expect(coordinator.state.dispatcherActive == false)
        #expect(fixture.gate.micOpen)
    }

    @Test func readAloudUsesOnDeviceSpeechAndLeavesOutAnUnconfirmedAddress() throws {
        let fixture = try Fixture()
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.startCpr)

        #expect(coordinator.callerScript.locationLine.hasPrefix("Location unknown"))

        coordinator.location.set(CallerLocation(address: "1 Test Way", accuracyMeters: 40, confirmed: false))
        let unconfirmed = coordinator.callerScript
        #expect(unconfirmed.locationLine.hasPrefix("Approximate, confirm:"))
        #expect(!unconfirmed.readAloud.contains("1 Test Way"))

        coordinator.location.confirmAddress()
        let confirmed = coordinator.callerScript
        #expect(confirmed.readAloud.contains("1 Test Way"))

        coordinator.readAloud(confirmed.readAloud)
        #expect(fixture.audio.calls.contains(.speak(confirmed.readAloud)))
        #expect(confirmed.readAloud.hasPrefix("I am an AI assistant"))
    }

    @Test func restartingForgetsAConfirmedAddress() throws {
        let fixture = try Fixture()
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.location.set(CallerLocation(address: "Old Venue", accuracyMeters: 40, confirmed: true))
        #expect(coordinator.callerScript.readAloud.contains("Old Venue"))

        coordinator.restartRescue()
        #expect(coordinator.location.current == nil)
        #expect(!coordinator.callerScript.readAloud.contains("Old Venue"))
    }

    @Test func aNewFixCannotReplaceAConfirmedAddress() throws {
        let fixture = try Fixture()
        let location = fixture.coordinator.location
        location.set(CallerLocation(address: "Confirmed Way", accuracyMeters: 40, confirmed: true))
        location.received(CLLocation(latitude: 1, longitude: 2))
        #expect(location.current?.address == "Confirmed Way")
        #expect(location.current?.confirmed == true)
    }

    @Test func anUnconfirmedAddressDoesTakeANewFix() throws {
        let fixture = try Fixture()
        let location = fixture.coordinator.location
        location.received(CLLocation(latitude: 1, longitude: 2))
        #expect(location.current?.address == "1.00000, 2.00000")
        #expect(location.current?.confirmed == false)
        location.reset() // Before the street address lookup this fix started can run.
    }

    @Test func theOnSceneListTagsWhatOnlyTheModelReported() throws {
        let fixture = try Fixture()
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.startCpr)
        coordinator.dispatch(.model(ModelProposal(
            action: .reportResources([.aed]),
            stateVersion: coordinator.state.version,
            issuedAt: fixture.clock.now
        )))
        #expect(coordinator.callerScript.resources == ["aed (AI-inferred)"])
    }

    @Test func secondPersonShowsAsAResource() throws {
        let fixture = try Fixture()
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.secondPerson)
        #expect(coordinator.state.resources.contains(.secondPerson))
        #expect(fixture.audio.played.contains("assign_helper"))
    }
}

/// Everything that decides whether a frame or a word leaves the phone, tested without the session's
/// own backstop, so a check here can't hide behind a check there.
@Suite struct UplinkGateTests {
    private let open = RuntimePolicy(modelSpeechOpen: true, micUplink: true, frameUplink: true, audioMode: .full)
    private let closed = RuntimePolicy(modelSpeechOpen: false, micUplink: false, frameUplink: false, audioMode: .full)

    private func drain(_ gate: UplinkGate, _ stream: AsyncStream<LiveCommand>, _ continuation: AsyncStream<LiveCommand>.Continuation) async -> [LiveCommand] {
        continuation.finish()
        gate.setCommands(nil)
        var all: [LiveCommand] = []
        for await command in stream { all.append(command) }
        return all
    }

    @Test func nothingIsQueuedForTheNetworkWhileThePolicyIsClosed() async {
        let gate = UplinkGate()
        let (stream, continuation) = AsyncStream.makeStream(of: LiveCommand.self)
        gate.setCommands(continuation)

        // Closed until the engine has said anything at all.
        gate.sendMicAudio(Data([1]))
        gate.sendAudioEnd()
        gate.sendFrame(Data([2]))
        gate.setPolicy(closed)
        gate.sendMicAudio(Data([1]))
        gate.sendAudioEnd()
        gate.sendFrame(Data([2]))
        #expect(await drain(gate, stream, continuation).isEmpty)
    }

    @Test func anOpenPolicyLetsThemThrough() async {
        let gate = UplinkGate()
        let (stream, continuation) = AsyncStream.makeStream(of: LiveCommand.self)
        gate.setCommands(continuation)
        gate.setPolicy(open)
        gate.sendMicAudio(Data([1]))
        gate.sendAudioEnd()
        gate.sendFrame(Data([2]))
        #expect(await drain(gate, stream, continuation).count == 3)
    }

    @Test func aBargeInHoldsModelAudioUntilItEnds() {
        let gate = UplinkGate()
        gate.setPolicy(open)
        #expect(gate.modelAudioOpen)
        gate.setBargeIn(true)
        #expect(!gate.modelAudioOpen)
        gate.setBargeIn(false)
        #expect(gate.modelAudioOpen)
    }

    @Test func theLocatorSendsNoFrameWhileTheGateIsClosed() async {
        let calls = Mutex(0)
        let http: HTTPClient = { request in
            calls.withLock { $0 += 1 }
            let text = #"{\"boxes\":[{\"box_2d\":[100,200,600,800],\"label\":\"aed\"}]}"#
            let body = #"{"candidates":[{"content":{"parts":[{"text":"\#(text)"}]}}]}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
        let gate = UplinkGate()
        let locator = GeminiObjectLocator(locator: GeminiLocator(apiKey: APIKey("test"), http: http), gate: gate)

        #expect(await locator.locate(jpeg: Data([0xFF, 0xD8]), label: "aed") == nil)
        gate.setPolicy(closed)
        #expect(await locator.locate(jpeg: Data([0xFF, 0xD8]), label: "aed") == nil)
        #expect(calls.withLock { $0 } == 0, "the image never left the phone")

        gate.setPolicy(open)
        #expect(await locator.locate(jpeg: Data([0xFF, 0xD8]), label: "aed") != nil)
        #expect(calls.withLock { $0 } == 1)
    }
}

@MainActor
@Suite struct AEDLocateTests {
    @Test func aScanLocatesWithoutWaitingForTheModel() throws {
        let fixture = try Fixture(canLocate: true)
        fixture.coordinator.beginRescue()
        fixture.coordinator.perform(.startCpr)
        fixture.coordinator.perform(.scan)
        #expect(fixture.vision.locateCount == 1)
        #expect(fixture.vision.bursts == 1)
    }

    @Test func aMissTriesAgainButAnAnswerInFlightIsLeftAlone() throws {
        let fixture = try Fixture(canLocate: true)
        fixture.coordinator.beginRescue()
        fixture.coordinator.perform(.startCpr)
        fixture.coordinator.perform(.scan)

        fixture.vision.setAEDStatus(.locating)
        fixture.run(seconds: 5)
        #expect(fixture.vision.locateCount == 1)

        fixture.vision.setAEDStatus(.notFound)
        fixture.run(seconds: 1)
        #expect(fixture.vision.locateCount == 2)

        fixture.vision.setAEDStatus(.located)
        fixture.run(seconds: 5)
        #expect(fixture.vision.locateCount == 2)
    }

    @Test func noKeyMeansNoLocate() throws {
        let fixture = try Fixture(canLocate: false)
        fixture.coordinator.beginRescue()
        fixture.coordinator.perform(.startCpr)
        fixture.coordinator.perform(.scan)
        fixture.run(seconds: 3)
        #expect(fixture.vision.locateCount == 0)
    }
}
