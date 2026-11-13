import Foundation
@testable import RescueCore
import Testing
@testable import RescueLive

@Suite struct LiveSessionTests {
    private func configuration(setupTimeout: TimeInterval = 30) -> LiveSession.Configuration {
        var configuration = LiveSession.Configuration()
        configuration.setupTimeouts = [setupTimeout]
        configuration.backoff = [0.001]
        return configuration
    }

    private struct Fixture {
        let mock = MockTransport()
        let clock = TestClock()
        let session: LiveSession
        let events: EventRecorder

        init(configuration: LiveSession.Configuration) {
            session = LiveSession(transport: mock, configuration: configuration, clock: clock.reader)
            events = EventRecorder(session.events)
        }

        /// Starts and reaches `.ready` on the first connection.
        func startReady() async throws {
            await session.start()
            try await waitForRequests(1)
            mock.emit(.ready)
            try await waitFor(.connected(resumed: false))
        }

        func waitFor(_ event: LiveEvent, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let found = await eventually { events.contains(event) }
            try #require(found, "never saw \(event)", sourceLocation: sourceLocation)
        }

        func waitForRequests(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let found = await eventually { mock.requests.count >= count }
            try #require(found, "never reached \(count) connects", sourceLocation: sourceLocation)
        }

        func waitForSent(_ message: RealtimeOutbound, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let found = await eventually { mock.sent.contains(message) }
            try #require(found, "never sent \(message)", sourceLocation: sourceLocation)
        }

        /// Plays a real Gemini JSON frame through the codec.
        func play(_ frame: String) throws {
            for event in GeminiCodec.inbound(from: try decodeServer(frame)) { mock.emit(event) }
        }
    }

    // MARK: - Basics

    @Test func theDefaultsMatchThePlan() {
        let defaults = LiveSession.Configuration()
        #expect(defaults.setupTimeouts == [3, 5, 8, 12])
        #expect((defaults.backoff.max() ?? 99) <= 5)
    }

    @Test func connectsAndReportsSetupTime() async throws {
        let fixture = Fixture(configuration: configuration())
        await fixture.session.start()
        try await fixture.waitForRequests(1)
        #expect(fixture.mock.requests[0] == RealtimeConnectRequest(resumeHandle: nil, seedsHistory: false))

        fixture.clock.advance(0.4)
        fixture.mock.emit(.ready)
        try await fixture.waitFor(.connected(resumed: false))
        #expect(abs((fixture.events.timing(.setup) ?? 0) - 0.4) < 1e-6)
    }

    @Test func startTwiceConnectsOnce() async throws {
        let fixture = Fixture(configuration: configuration())
        await fixture.session.start()
        await fixture.session.start()
        try await fixture.waitForRequests(1)
        try await Task.sleep(for: .milliseconds(20))
        #expect(fixture.mock.requests.count == 1)
    }

    @Test func serverContentBecomesEvents() async throws {
        let fixture = Fixture(configuration: configuration())
        try await fixture.startReady()
        try fixture.play("""
        {"serverContent":{
          "modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AQID"}}]},
          "inputTranscription":{"text":"he is gasping"},
          "outputTranscription":{"text":"keep going"},
          "turnComplete":true
        },"usageMetadata":{"totalTokenCount":5}}
        """)
        try fixture.play(#"{"serverContent":{"interrupted":true}}"#)
        try await fixture.waitFor(.interrupted)

        let events = fixture.events
        #expect(events.contains(.modelAudio(Data([1, 2, 3]))))
        #expect(events.contains(.inputTranscript("he is gasping")))
        #expect(events.contains(.outputTranscript("keep going")))
        #expect(events.contains(.turnComplete))
        #expect(events.contains(.usage(LiveUsage(totalTokens: 5))))
    }

    @Test func aToolCallBecomesAProposalAndASilentResponse() async throws {
        let fixture = Fixture(configuration: configuration())
        try await fixture.startReady()
        try fixture.play("""
        {"toolCall":{"functionCalls":[{"id":"c1","name":"report_finding","args":{
          "kind":"not_breathing","source":"heard","confidence":"high","state_version":4
        }}]}}
        """)
        try await fixture.waitForSent(.toolResponses([
            ToolResponse(id: "c1", name: "report_finding", status: .received, reason: nil),
        ]))
        #expect(fixture.events.proposals == [ModelProposal(
            action: .reportFinding(.notBreathing, source: .heard, confidence: .high),
            stateVersion: 4,
            issuedAt: fixture.clock.now
        )])
    }

    @Test func aHostileToolCallIsRejectedWithNoProposal() async throws {
        let fixture = Fixture(configuration: configuration())
        try await fixture.startReady()
        try fixture.play("""
        {"toolCall":{"functionCalls":[
          {"id":"c1","name":"stop_metronome","args":{"state_version":4}},
          {"id":"c2","name":"say","args":{"phrase_id":"keep_going"}},
          {"id":"c3","name":"report_finding","args":{"kind":"dead","source":"seen","confidence":"high","state_version":4}},
          {"name":"say"},
          {"id":"c5","args":[1,2,3]}
        ]}}
        """)
        try await fixture.waitForSent(.toolResponses([
            ToolResponse(id: "c1", name: "stop_metronome", status: .rejected, reason: .unknownTool),
            ToolResponse(id: "c2", name: "say", status: .rejected, reason: .missingStateVersion),
            ToolResponse(id: "c3", name: "report_finding", status: .rejected, reason: .unknownValue),
            ToolResponse(id: "c5", name: "unknown", status: .rejected, reason: .unknownTool),
        ]))
        #expect(fixture.events.proposals.isEmpty)
    }

    @Test func garbageFromTheServerDoesNothing() async throws {
        let fixture = Fixture(configuration: configuration())
        try await fixture.startReady()
        try fixture.play(#"{"somethingNew":true,"toolCall":{"functionCalls":"x"}}"#)
        fixture.mock.emit(.functionCallsCancelled(["c1"]))
        fixture.mock.emit(.ready)
        try await Task.sleep(for: .milliseconds(20))
        #expect(fixture.events.disconnects.isEmpty)
        #expect(fixture.mock.requests.count == 1)
    }

    // MARK: - Setup watchdog

    @Test func theWatchdogFiresAndRetries() async throws {
        let fixture = Fixture(configuration: configuration(setupTimeout: 0.01))
        await fixture.session.start()
        try await fixture.waitFor(.disconnected(.setupTimeout))
        try await fixture.waitForRequests(2)
        #expect(fixture.mock.closedCount >= 1)
    }

    @Test func theWatchdogDoesNotFireOnceReady() async throws {
        let fixture = Fixture(configuration: configuration(setupTimeout: 0.03))
        try await fixture.startReady()
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.events.disconnects.isEmpty)
    }

    @Test func eachSetupTimeoutGivesTheNextAttemptLonger() async throws {
        var settings = configuration()
        settings.setupTimeouts = [0.01, 60]
        let fixture = Fixture(configuration: settings)
        await fixture.session.start()
        try await fixture.waitFor(.disconnected(.setupTimeout))
        try await fixture.waitForRequests(2)
        // The second attempt has the longer budget, and is still waiting long after the first gave up.
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.mock.requests.count == 2)
        #expect(fixture.events.disconnects.count == 1)
        fixture.mock.emit(.ready)
        try await fixture.waitFor(.connected(resumed: false))
    }

    @Test func aFinishedSetupStartsTheTimeoutsOver() async throws {
        var settings = configuration()
        settings.setupTimeouts = [0.01, 60]
        let fixture = Fixture(configuration: settings)
        await fixture.session.start()
        try await fixture.waitForRequests(2)
        fixture.mock.emit(.ready)
        try await fixture.waitFor(.connected(resumed: false))

        // The next attempt is back on the short budget, so it times out again and a third follows.
        fixture.mock.emit(.closed(.networkFailure(code: nil)))
        try await fixture.waitForRequests(3)
        try await fixture.waitForRequests(4)
    }

    @Test func aRefusedConnectionDoesNotStretchTheTimeout() async throws {
        var settings = configuration()
        settings.setupTimeouts = [0.1, 60]
        let fixture = Fixture(configuration: settings)
        await fixture.session.start()
        try await fixture.waitForRequests(1)
        fixture.mock.emit(.closed(.networkFailure(code: nil)))
        try await fixture.waitForRequests(2)
        // Still on the short budget, so this one times out by itself.
        try await fixture.waitFor(.disconnected(.setupTimeout))
    }

    // MARK: - Reconnecting

    @Test func goAwayResumesWithTheStoredHandle() async throws {
        // A long backoff, to show that a planned move on a healthy connection doesn't wait for it.
        var settings = configuration()
        settings.backoff = [60]
        let fixture = Fixture(configuration: settings)
        try await fixture.startReady()
        await fixture.session.sendStateBrief(brief(version: 2))
        try await fixture.waitForSent(.stateBrief(brief(version: 2), seed: false))

        fixture.mock.emit(.resumption(handle: "h1", resumable: true))
        fixture.clock.advance(60)
        try fixture.play(#"{"goAway":{"timeLeft":"50s"}}"#)
        try await fixture.waitFor(.disconnected(.goAway))
        try await fixture.waitForRequests(2)
        #expect(fixture.mock.requests[1] == RealtimeConnectRequest(resumeHandle: "h1", seedsHistory: false))

        fixture.mock.clearSent()
        fixture.mock.emit(.ready)
        try await fixture.waitFor(.connected(resumed: true))
        try await fixture.waitForSent(.stateBrief(brief(version: 2), seed: false))
    }

    @Test func aGoAwayRightAfterConnectingBacksOffInsteadOfSpinning() async throws {
        var settings = configuration()
        settings.backoff = [60]
        let fixture = Fixture(configuration: settings)
        try await fixture.startReady()
        fixture.mock.emit(.goAway(secondsLeft: 1))
        try await fixture.waitFor(.disconnected(.goAway))
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.mock.requests.count == 1)
        await fixture.session.stop()
    }

    @Test func aGoAwayKeepsTheHandleEvenOnAShortConnection() async throws {
        let fixture = Fixture(configuration: configuration())
        try await fixture.startReady()
        fixture.mock.emit(.resumption(handle: "h1", resumable: true))
        fixture.mock.emit(.goAway(secondsLeft: 1))
        try await fixture.waitForRequests(2)
        #expect(fixture.mock.requests[1].resumeHandle == "h1")
    }

    @Test func aHandleThatIsNotResumableDoesNotReplaceAGoodOne() async throws {
        let fixture = Fixture(configuration: configuration())
        try await fixture.startReady()
        fixture.mock.emit(.resumption(handle: "good", resumable: true))
        fixture.mock.emit(.resumption(handle: nil, resumable: false))
        fixture.mock.emit(.resumption(handle: "bad", resumable: false))
        fixture.mock.emit(.resumption(handle: "", resumable: true))
        fixture.clock.advance(60)
        fixture.mock.emit(.goAway(secondsLeft: nil))
        try await fixture.waitForRequests(2)
        #expect(fixture.mock.requests[1].resumeHandle == "good")
    }

    @Test func anUnexpectedCloseWithNoHandleRebuildsFromTheLatestBriefOnly() async throws {
        let fixture = Fixture(configuration: configuration())
        try await fixture.startReady()
        await fixture.session.sendStateBrief(brief(version: 1))
        await fixture.session.sendStateBrief(brief(version: 2))
        try fixture.play(#"{"serverContent":{"inputTranscript":{"text":"x"},"inputTranscription":{"text":"TRANSCRIPT-SECRET"},"outputTranscription":{"text":"MODEL-LINE"}}}"#)
        try await fixture.waitFor(.outputTranscript("MODEL-LINE"))

        fixture.mock.clearSent()
        fixture.mock.emit(.closed(.closedByServer(code: 1011, reason: "internal")))
        try await fixture.waitFor(.disconnected(.closedByServer(code: 1011, reason: "internal")))
        try await fixture.waitForRequests(2)
        #expect(fixture.mock.requests[1] == RealtimeConnectRequest(resumeHandle: nil, seedsHistory: true))

        fixture.mock.emit(.ready)
        try await fixture.waitForSent(.stateBrief(brief(version: 2), seed: true))
        #expect(fixture.mock.sent == [.stateBrief(brief(version: 2), seed: true)])
    }

    @Test func theSeedGoesOutBeforeAnyRealtimeInput() async throws {
        let fixture = Fixture(configuration: configuration())
        await fixture.session.sendStateBrief(brief(version: 5))
        await fixture.session.start()
        try await fixture.waitForRequests(1)
        #expect(fixture.mock.requests[0].seedsHistory)

        fixture.mock.setSendsHeld(true)
        fixture.mock.emit(.ready)
        try await fixture.waitFor(.connected(resumed: false))
        await fixture.session.sendAudio(Data([1]))
        await fixture.session.sendFrame(Data([2]))
        fixture.mock.setSendsHeld(false)
        try await fixture.waitForSent(.frame(jpeg: Data([2])))
        #expect(fixture.mock.sent == [
            .stateBrief(brief(version: 5), seed: true),
            .audio(Data([1])),
            .frame(jpeg: Data([2])),
        ])
    }

    @Test func aFailedResumeFallsBackToAFreshConnection() async throws {
        let fixture = Fixture(configuration: configuration())
        try await fixture.startReady()
        await fixture.session.sendStateBrief(brief(version: 3))
        fixture.mock.emit(.resumption(handle: "stale", resumable: true))
        fixture.clock.advance(60)
        fixture.mock.emit(.goAway(secondsLeft: nil))
        try await fixture.waitForRequests(2)
        #expect(fixture.mock.requests[1].resumeHandle == "stale")

        // The resume is refused before setup completes.
        fixture.mock.emit(.closed(.closedByServer(code: 1008, reason: nil)))
        try await fixture.waitForRequests(3)
        #expect(fixture.mock.requests[2] == RealtimeConnectRequest(resumeHandle: nil, seedsHistory: true))
    }

    @Test func aStableConnectionKeepsItsHandleAcrossAnUnexpectedClose() async throws {
        let fixture = Fixture(configuration: configuration())
        try await fixture.startReady()
        fixture.mock.emit(.resumption(handle: "h1", resumable: true))
        try await Task.sleep(for: .milliseconds(10))
        fixture.clock.advance(60)
        fixture.mock.emit(.closed(.networkFailure(code: -1005)))
        try await fixture.waitForRequests(2)
        #expect(fixture.mock.requests[1].resumeHandle == "h1")
    }

    @Test func aStreamThatJustEndsCountsAsLost() async throws {
        let fixture = Fixture(configuration: configuration())
        try await fixture.startReady()
        fixture.mock.emit(.closed(.networkFailure(code: nil)))
        try await fixture.waitFor(.disconnected(.networkFailure(code: nil)))
        try await fixture.waitForRequests(2)
    }

    @Test func reconnectGapIsReported() async throws {
        let fixture = Fixture(configuration: configuration())
        try await fixture.startReady()
        fixture.mock.emit(.closed(.networkFailure(code: nil)))
        try await fixture.waitForRequests(2)
        fixture.clock.advance(1.5)
        fixture.mock.emit(.ready)
        try await fixture.waitFor(.timing(.reconnectGap, seconds: 1.5))
    }

    @Test func messagesFromAnOldConnectionAreIgnored() async throws {
        let fixture = Fixture(configuration: configuration())
        try await fixture.startReady()
        fixture.mock.emit(.closed(.networkFailure(code: nil)))
        try await fixture.waitForRequests(2)
        fixture.mock.emit(.closed(.setupTimeout), toConnection: 0)
        fixture.mock.emit(.outputTranscript("late"), toConnection: 0)
        await fixture.session.sendStateBrief(brief(version: 9))
        fixture.mock.emit(.ready, toConnection: 1)
        try await fixture.waitForSent(.stateBrief(brief(version: 9), seed: false))
        #expect(!fixture.events.contains(.outputTranscript("late")))
        #expect(fixture.events.disconnects.count == 1)
    }

    @Test func backoffIsSmallAndBounded() {
        let schedule = LiveSession.Configuration().backoff
        let delays = (1...50).map { LiveSession.backoffDelay(failures: $0, schedule: schedule) }
        #expect(delays[0] == 0.25)
        #expect(delays == delays.sorted())
        #expect(delays.last == 4)
        #expect(LiveSession.backoffDelay(failures: 3, schedule: []) == 1)
    }

    @Test func invalidConfigurationDoesNotRetry() async throws {
        let fixture = Fixture(configuration: configuration())
        await fixture.session.start()
        try await fixture.waitForRequests(1)
        fixture.mock.emit(.closed(.invalidConfiguration))
        try await fixture.waitFor(.disconnected(.invalidConfiguration))
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.mock.requests.count == 1)
    }

    // MARK: - Stop

    @Test func stopEndsItAndStopsRetrying() async throws {
        let fixture = Fixture(configuration: configuration(setupTimeout: 0.005))
        await fixture.session.start()
        try await fixture.waitForRequests(2)
        await fixture.session.stop()
        try await fixture.waitFor(.disconnected(.stopped))
        let count = fixture.mock.requests.count
        try await Task.sleep(for: .milliseconds(40))
        #expect(fixture.mock.requests.count == count)
        #expect(fixture.mock.closedCount == count)
    }

    @Test func stopWhenIdleEmitsNothing() async throws {
        let fixture = Fixture(configuration: configuration())
        await fixture.session.stop()
        try await Task.sleep(for: .milliseconds(10))
        #expect(fixture.events.all.isEmpty)
    }

    // MARK: - Sending

    @Test func sendsAreDroppedUntilReady() async throws {
        let fixture = Fixture(configuration: configuration())
        await fixture.session.sendAudio(Data([1]))
        await fixture.session.sendFrame(Data([2]))
        await fixture.session.sendAudioStreamEnd()
        await fixture.session.start()
        try await fixture.waitForRequests(1)
        await fixture.session.sendAudio(Data([3]))
        await fixture.session.sendFrame(Data([4]))
        fixture.mock.emit(.ready)
        try await fixture.waitFor(.connected(resumed: false))
        await fixture.session.sendAudio(Data([5]))
        try await fixture.waitForSent(.audio(Data([5])))
        #expect(fixture.mock.sent == [.audio(Data([5]))])
    }

    @Test func sendsAreDroppedWhileReconnecting() async throws {
        let fixture = Fixture(configuration: configuration())
        try await fixture.startReady()
        fixture.mock.emit(.closed(.networkFailure(code: nil)))
        try await fixture.waitForRequests(2)
        await fixture.session.sendAudio(Data([1]))
        await fixture.session.sendFrame(Data([2]))
        fixture.mock.emit(.ready)
        try await Task.sleep(for: .milliseconds(20))
        #expect(fixture.mock.sent.isEmpty)
    }

    @Test func framesAreLatestWinsWhileTheSocketIsBusy() async throws {
        let fixture = Fixture(configuration: configuration())
        try await fixture.startReady()
        fixture.mock.setSendsHeld(true)
        await fixture.session.sendAudio(Data([0]))
        await fixture.session.sendFrame(Data([1]))
        await fixture.session.sendFrame(Data([2]))
        await fixture.session.sendFrame(Data([3]))
        fixture.mock.setSendsHeld(false)
        try await fixture.waitForSent(.frame(jpeg: Data([3])))
        #expect(fixture.mock.sent == [.audio(Data([0])), .frame(jpeg: Data([3]))])
    }

    @Test func aStalledSocketNeverBlocksCallersAndAudioStaysBounded() async throws {
        var config = configuration()
        config.maxQueuedAudioBytes = 4
        let fixture = Fixture(configuration: config)
        try await fixture.startReady()
        fixture.mock.setSendsHeld(true)
        await fixture.session.sendAudio(Data([0, 0]))

        let started = ContinuousClock.now
        for byte in UInt8(1)...200 { await fixture.session.sendAudio(Data([byte, byte])) }
        #expect(ContinuousClock.now - started < .seconds(1))

        fixture.mock.setSendsHeld(false)
        try await fixture.waitForSent(.audio(Data([200, 200])))
        let audio = fixture.mock.sent.filter { if case .audio = $0 { true } else { false } }
        #expect(audio.count <= 4)
    }

    @Test func aSendFailureIsOnlyAnEvent() async throws {
        let fixture = Fixture(configuration: configuration())
        try await fixture.startReady()
        fixture.mock.setSendsFail(true)
        await fixture.session.sendAudio(Data([1]))
        try await fixture.waitFor(.disconnected(.sendFailed))
        try await fixture.waitForRequests(2)
    }

    @Test func anOlderBriefCannotReplaceANewerOne() async throws {
        let fixture = Fixture(configuration: configuration())
        await fixture.session.sendStateBrief(brief(version: 5))
        await fixture.session.sendStateBrief(brief(version: 3))
        await fixture.session.start()
        try await fixture.waitForRequests(1)
        fixture.mock.emit(.ready)
        try await fixture.waitForSent(.stateBrief(brief(version: 5), seed: true))
    }

    // MARK: - Policy

    private func policy(mic: Bool, frames: Bool) -> RuntimePolicy {
        RuntimePolicy(modelSpeechOpen: false, micUplink: mic, frameUplink: frames, audioMode: .full)
    }

    @Test func closedPolicyStopsUplinkAndEndsTheAudioStream() async throws {
        let fixture = Fixture(configuration: configuration())
        try await fixture.startReady()
        await fixture.session.applyPolicy(policy(mic: false, frames: false))
        try await fixture.waitForSent(.audioStreamEnd)

        await fixture.session.sendAudio(Data([1]))
        await fixture.session.sendFrame(Data([2]))
        try await Task.sleep(for: .milliseconds(20))
        #expect(fixture.mock.sent == [.audioStreamEnd])

        await fixture.session.applyPolicy(policy(mic: true, frames: true))
        await fixture.session.sendAudio(Data([3]))
        await fixture.session.sendFrame(Data([4]))
        try await fixture.waitForSent(.frame(jpeg: Data([4])))
        #expect(fixture.mock.sent == [.audioStreamEnd, .audio(Data([3])), .frame(jpeg: Data([4]))])
    }

    @Test func closingThePolicyDropsWhatIsAlreadyQueued() async throws {
        let fixture = Fixture(configuration: configuration())
        try await fixture.startReady()
        fixture.mock.setSendsHeld(true)
        await fixture.session.sendAudio(Data([0]))
        await fixture.session.sendAudio(Data([1]))
        await fixture.session.sendFrame(Data([2]))
        await fixture.session.applyPolicy(policy(mic: false, frames: false))
        fixture.mock.setSendsHeld(false)
        try await fixture.waitForSent(.audioStreamEnd)
        #expect(!fixture.mock.sent.contains(.audio(Data([1]))))
        #expect(!fixture.mock.sent.contains(.frame(jpeg: Data([2]))))
    }

    // MARK: - Timing

    @Test func speechEndTimingsMeasureTheFirstOfEach() async throws {
        let fixture = Fixture(configuration: configuration())
        try await fixture.startReady()
        await fixture.session.sendAudioStreamEnd()
        try await fixture.waitForSent(.audioStreamEnd)

        fixture.clock.advance(1.25)
        fixture.mock.emit(.functionCalls([RealtimeFunctionCall(id: "a", name: "junk", args: nil)]))
        try await fixture.waitFor(.timing(.speechEndToToolCall, seconds: 1.25))

        fixture.clock.advance(0.75)
        fixture.mock.emit(.audio(Data([1])))
        try await fixture.waitFor(.timing(.speechEndToModelAudio, seconds: 2))

        fixture.clock.advance(5)
        fixture.mock.emit(.audio(Data([2])))
        try await fixture.waitFor(.modelAudio(Data([2])))
        #expect(fixture.events.timing(.speechEndToModelAudio) == 2)
    }

    @Test func aDroppedSessionFinishesItsEventStream() async throws {
        var session: LiveSession? = LiveSession(transport: MockTransport(), clock: { 0 })
        let stream = session!.events
        session = nil
        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 0)
    }
}
