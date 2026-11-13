import Foundation
import PlumbContracts
import Testing
@testable import PlumbAgents

/// One voice session wired to a scripted socket, with everything a test wants to look at.
private struct Rig: Sendable {
    let session: VoiceSession
    let socket: ScriptedSocket
    let events: EventLog
    let handshakes: Locked<[URLRequest]>
    let logged: Locked<[LogEntry.Body]>

    init(socket: ScriptedSocket = ScriptedSocket(), config: AgentsConfig = AgentsConfig(),
         read: @escaping @Sendable () async -> WorldDigest = { freshDigest() }) async {
        let handshakes = Locked<[URLRequest]>([])
        let logged = Locked<[LogEntry.Body]>([])
        let conductor = Conductor(config: config, now: { 0 }, sink: { body in logged.with { $0.append(body) } })
        await conductor.register(GetCPRQuality(deadline: .seconds(30), read: read))
        session = VoiceSession(apiKey: secretKey, socketFactory: { request -> any RealtimeSocket in
            handshakes.with { $0.append(request) }
            return socket
        }, conductor: conductor, config: config)
        self.socket = socket
        self.handshakes = handshakes
        self.logged = logged
        events = EventLog(session.events)
    }

    /// Connects and lets the service accept the setup.
    func connectAndAccept() async {
        await session.connect()
        socket.serverSends(#"{"setupComplete": {}}"#)
        _ = await events.waitFor(.connected)
    }

    /// The tool responses sent so far.
    var toolResponses: [JSONValue] {
        socket.sent.compactMap { $0["toolResponse"] }
    }
}

@Suite struct VoiceSessionTests {

    // MARK: Connecting

    @Test func theHandshakeCarriesTheKeyInAHeaderAndNeverInTheURL() async throws {
        let rig = await Rig()

        await rig.session.connect()

        let request = try #require(rig.handshakes.current.first)
        let url = try #require(request.url)
        #expect(url.absoluteString == "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")
        #expect(url.query == nil)
        #expect(!url.absoluteString.contains(secretKey))
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == secretKey)
        #expect(!rig.socket.sent.description.contains(secretKey))
    }

    @Test func setupDeclaresTheOneToolAndTurnsOffAutomaticVoiceDetection() async throws {
        let rig = await Rig()

        await rig.session.connect()

        let setup = try #require(rig.socket.sent.first?["setup"])
        #expect(rig.socket.sent.count == 1)
        #expect(setup["model"] == "models/gemini-3.8-live")
        #expect(setup["generationConfig"] == ["responseModalities": ["AUDIO"]])
        #expect(setup["realtimeInputConfig"] == ["automaticActivityDetection": ["disabled": true]])
        #expect(setup["inputAudioTranscription"] == [:])
        #expect(setup["outputAudioTranscription"] == [:])

        let tools = try #require(setup["tools"]?.array)
        #expect(tools.count == 1)
        let declarations = try #require(tools.first?["functionDeclarations"]?.array)
        #expect(declarations.count == 1)
        #expect(declarations.first?["name"] == "get_cpr_quality")
        #expect(declarations.first?["parameters"] == nil)
        let description = try #require(declarations.first?["description"]?.string)
        #expect(description.hasPrefix("Call this before answering any question about how the compressions are going."))
        #expect(description.contains("one short sentence using only the numbers it returns"))
        #expect(description.contains("stale is true, say that you cannot see the hands right now"))

        let system = try #require(setup["systemInstruction"]?["parts"]?.array?.first?["text"]?.string)
        #expect(system == VoicePrompt.system)
    }

    @Test func aChosenVoiceGoesIntoTheSetup() async throws {
        var config = AgentsConfig()
        config.voiceName = "Kore"
        let rig = await Rig(config: config)

        await rig.session.connect()

        let generation = try #require(rig.socket.sent.first?["setup"]?["generationConfig"])
        #expect(generation["speechConfig"] == ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": "Kore"]]])
    }

    @Test func connectedIsOnlyAnnouncedOnceTheServiceAcceptsTheSetup() async {
        let rig = await Rig()

        await rig.session.connect()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!rig.events.all.contains(.connected))

        rig.socket.serverSends(#"{"setupComplete": {}}"#, asBinary: true)
        #expect(await rig.events.waitFor(.connected))
    }

    @Test func aFailedConnectionIsReportedWithoutTheKey() async {
        let failure = TalkativeError(text: "handshake to wss://host/?key=\(secretKey) refused")
        let rig = await Rig(socket: ScriptedSocket(connectFailure: failure))

        await rig.session.connect()

        let reason = "Could not reach the voice service. The connection to the voice service was lost: handshake to wss://host/?key=[key] refused"
        #expect(await rig.events.waitFor(.disconnected(reason: reason)))
        #expect(rig.events.all == [.failed(reason: reason), .disconnected(reason: reason)])
        #expect(rig.socket.isClosed)
    }

    @Test func aServiceThatNeverAnswersTheSetupIsGivenUpOn() async {
        var config = AgentsConfig()
        config.voiceSetupTimeout = .milliseconds(100)
        let rig = await Rig(config: config)

        await rig.session.connect()

        let reason = "The voice service did not answer in time."
        #expect(await rig.events.waitFor(.disconnected(reason: reason)))
        #expect(rig.events.all == [.failed(reason: reason), .disconnected(reason: reason)])
        #expect(rig.socket.isClosed)
    }

    // MARK: Talking

    @Test func talkingSendsActivityStartThenAudioThenActivityEnd() async {
        let rig = await Rig()
        await rig.connectAndAccept()
        let chunk = Data([0x01, 0x02, 0x03, 0x04])

        rig.session.beginTalking()
        rig.session.sendAudio(pcm16k: chunk)
        rig.session.sendAudio(pcm16k: chunk)
        rig.session.endTalking()

        let sent = await rig.socket.waitForSent(5)
        let audio: JSONValue = ["realtimeInput": ["audio": ["data": .string(chunk.base64EncodedString()), "mimeType": "audio/pcm;rate=16000"]]]
        #expect(Array(sent.dropFirst()) == [
            ["realtimeInput": ["activityStart": [:]]],
            audio,
            audio,
            ["realtimeInput": ["activityEnd": [:]]],
        ])
    }

    @Test func audioOutsideAHeldTurnNeverLeavesThePhone() async {
        let rig = await Rig()
        await rig.connectAndAccept()

        rig.session.sendAudio(pcm16k: Data([9, 9]))
        rig.session.beginTalking()
        rig.session.endTalking()
        rig.session.sendAudio(pcm16k: Data([9, 9]))
        rig.session.beginTalking()
        rig.session.endTalking()

        let sent = await rig.socket.waitForSent(5)
        #expect(sent.count == 5)
        #expect(sent.allSatisfy { $0["realtimeInput"]?["audio"] == nil })
    }

    @Test func talkingBeforeConnectingSendsNothingAndSaysSo() async {
        let rig = await Rig()

        rig.session.beginTalking()
        rig.session.sendAudio(pcm16k: Data([1, 2]))
        rig.session.endTalking()

        #expect(await rig.events.waitFor(.failed(reason: "Not connected to the voice service, so nothing was sent.")))
        #expect(rig.socket.sent.isEmpty)
        #expect(rig.handshakes.current.isEmpty)
    }

    // MARK: Messages from the service

    @Test func aToolCallGetsExactlyOneResponseCarryingTheDigest() async throws {
        let rig = await Rig()
        await rig.connectAndAccept()

        rig.socket.serverSends(#"{"toolCall": {"functionCalls": [{"id": "call-1", "name": "get_cpr_quality", "args": {}}]}}"#)

        _ = await rig.socket.waitForSent(2)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.toolResponses.count == 1)
        let responses = try #require(rig.toolResponses.first?["functionResponses"]?.array)
        #expect(responses.count == 1)
        let response = try #require(responses.first)
        #expect(response["id"] == "call-1")
        #expect(response["name"] == "get_cpr_quality")
        #expect(response["response"]?["error"] == nil)

        let result = try #require(response["response"]?["result"])
        let digest = try JSONDecoder().decode(WorldDigest.self, from: result.encoded())
        #expect(digest == GetCPRQuality.speakable(freshDigest()))
        #expect(digest.ratePerMin == 112)
        #expect(digest.depthMM == 54)
        #expect(digest.stale == false)

        #expect(rig.events.all.contains(.toolCalled(name: "get_cpr_quality")))
        #expect(rig.logged.current == [.toolCall(name: "get_cpr_quality", durationS: 0, ok: true,
                                                 summary: "87 compressions, 112 per minute, 54 mm deep, measured 0.4 seconds ago.")])
    }

    @Test func aStaleDigestReachesTheModelWithoutNumbers() async throws {
        let rig = await Rig(read: {
            var digest = freshDigest()
            digest.stale = true
            digest.ageS = 7
            return digest
        })
        await rig.connectAndAccept()

        rig.socket.serverSends(#"{"toolCall": {"functionCalls": [{"id": "call-1", "name": "get_cpr_quality"}]}}"#)

        _ = await rig.socket.waitForSent(2)
        let result = try #require(rig.toolResponses.first?["functionResponses"]?.array?.first?["response"]?["result"])
        #expect(result["stale"] == true)
        #expect(result["ageS"] == 7)
        #expect(result["ratePerMin"] == nil)
        #expect(result["depthMM"] == nil)
    }

    @Test func anUnknownToolGetsAnErrorResponse() async throws {
        let rig = await Rig()
        await rig.connectAndAccept()

        rig.socket.serverSends(#"{"toolCall": {"functionCalls": [{"id": "call-2", "name": "stop_the_beat", "args": {"now": true}}]}}"#)

        _ = await rig.socket.waitForSent(2)
        let response = try #require(rig.toolResponses.first?["functionResponses"]?.array?.first)
        #expect(response["id"] == "call-2")
        #expect(response["name"] == "stop_the_beat")
        #expect(response["response"] == ["error": "No tool called stop_the_beat is registered."])
        #expect(rig.logged.current.contains(.blocked(what: "Tool call stop_the_beat", rule: "No tool called stop_the_beat is registered.")))
    }

    @Test func aCancelledToolCallGetsNoResponse() async throws {
        let gate = Gate()
        let rig = await Rig(read: {
            await gate.wait()
            return freshDigest()
        })
        await rig.connectAndAccept()

        rig.socket.serverSends(#"{"toolCall": {"functionCalls": [{"id": "slow", "name": "get_cpr_quality", "args": {}}]}}"#)
        #expect(await eventually { gate.waiting == 1 })
        rig.socket.serverSends(#"{"toolCallCancellation": {"ids": ["slow"]}}"#)
        // Wait until the cancelled call has been written off, then let the tool finish late.
        #expect(await eventually { rig.logged.current.count == 1 })
        gate.open()

        rig.socket.serverSends(#"{"toolCall": {"functionCalls": [{"id": "next", "name": "get_cpr_quality", "args": {}}]}}"#)
        _ = await rig.socket.waitForSent(2)
        try? await Task.sleep(for: .milliseconds(100))

        #expect(rig.toolResponses.count == 1)
        #expect(rig.toolResponses.first?["functionResponses"]?.array?.first?["id"] == "next")
    }

    @Test func audioFromTheServiceComesOutAsSpeakingEvents() async {
        let rig = await Rig()
        await rig.connectAndAccept()
        let first = Data([0x10, 0x20, 0x30, 0x40]), second = Data([0x50, 0x60])

        rig.socket.serverSends("""
        {"serverContent": {"modelTurn": {"parts": [
            {"inlineData": {"mimeType": "audio/pcm;rate=24000", "data": "\(first.base64EncodedString())"}},
            {"text": "a thought, not audio"},
            {"inlineData": {"mimeType": "image/png", "data": "AAAA"}}
        ]}}}
        """)
        rig.socket.serverSends(#"{"serverContent": {"modelTurn": {"parts": [{"inlineData": {"mimeType": "audio/pcm;rate=24000", "data": "\#(second.base64EncodedString())"}}]}, "turnComplete": true}}"#, asBinary: true)

        #expect(await rig.events.waitFor(.turnEnded))
        #expect(rig.events.all == [.connected, .speaking(pcm24k: first), .speaking(pcm24k: second), .turnEnded])
    }

    @Test func transcriptionComesOutAsHeardAndReplied() async {
        let rig = await Rig()
        await rig.connectAndAccept()

        rig.socket.serverSends(#"{"serverContent": {"inputTranscription": {"text": "How am I doing?"}}}"#)
        rig.socket.serverSends(#"{"serverContent": {"outputTranscription": {"text": "112 per minute, 54 millimetres deep."}}}"#)

        #expect(await rig.events.waitFor(.replied(text: "112 per minute, 54 millimetres deep.")))
        #expect(rig.events.all == [.connected, .heard(text: "How am I doing?"),
                                   .replied(text: "112 per minute, 54 millimetres deep.")])
    }

    @Test func framesThatAreNotJSONOrNotUnderstoodAreIgnored() async {
        let rig = await Rig()
        await rig.connectAndAccept()

        rig.socket.serverSends("not json at all")
        rig.socket.serverSends(#"{"usageMetadata": {"totalTokenCount": 12}}"#)
        rig.socket.serverSends(#"{"serverContent": {"turnComplete": true}}"#)

        #expect(await rig.events.waitFor(.turnEnded))
        #expect(rig.events.all == [.connected, .turnEnded])
    }

    // MARK: Dropping

    @Test func aServerCloseYieldsDisconnectedWithoutTheKey() async throws {
        let rig = await Rig()
        await rig.connectAndAccept()

        rig.socket.serverCloses(code: 1008, reason: "API key \(secretKey) not valid.\nPlease pass a valid API key.")

        let event = try #require(await rig.events.waitForFirst {
            if case .disconnected = $0 { return true } else { return false }
        })
        #expect(event == .disconnected(reason: "The voice service closed the connection with code 1008: API key [key] not valid. Please pass a valid API key."))
        #expect(!String(describing: rig.events.all).contains(secretKey))
        #expect(rig.socket.isClosed)
    }

    @Test func thereIsNoAutomaticReconnect() async {
        let rig = await Rig()
        await rig.connectAndAccept()

        rig.socket.serverCloses(code: 1011, reason: "")
        #expect(await rig.events.waitFor(.disconnected(reason: "The voice service closed the connection with code 1011.")))
        try? await Task.sleep(for: .milliseconds(150))

        #expect(rig.handshakes.current.count == 1)
        // Talking after a drop goes nowhere.
        rig.session.beginTalking()
        #expect(await rig.events.waitFor(.failed(reason: "Not connected to the voice service, so nothing was sent.")))
        #expect(rig.socket.sent.count == 1)
    }

    @Test func aCloseBeforeTheSetupIsAcceptedIsAFailedConnection() async {
        let rig = await Rig()
        await rig.session.connect()

        rig.socket.serverCloses(code: 1007, reason: "Unknown field in setup.")

        let reason = "The voice service closed the connection with code 1007: Unknown field in setup."
        #expect(await rig.events.waitFor(.disconnected(reason: reason)))
        #expect(rig.events.all == [.failed(reason: reason), .disconnected(reason: reason)])
    }

    @Test func disconnectClosesTheSocketAndSaysSo() async {
        let rig = await Rig()
        await rig.connectAndAccept()

        await rig.session.disconnect()

        #expect(await rig.events.waitFor(.disconnected(reason: "Closed by the app.")))
        #expect(rig.socket.isClosed)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.events.all == [.connected, .disconnected(reason: "Closed by the app.")])
    }

    // MARK: The rules the model is given

    @Test func theSystemInstructionStatesEveryRule() {
        let required = [
            "voice of a CPR training simulator", "manikin", "never give instructions, advice",
            "fixed on-screen prompts", "only answer questions by reading out the measurements",
            "get_cpr_quality", "one short sentence", "plain words", "no medical claims",
            "say that you can only report the measurements",
        ]
        for phrase in required {
            #expect(VoicePrompt.system.localizedCaseInsensitiveContains(phrase), "missing: \(phrase)")
        }
    }
}
