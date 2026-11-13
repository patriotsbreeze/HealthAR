import Foundation
import RescueCore
import Synchronization
import Testing
@testable import RescueLive

/// A socket with scripted frames. `receive` waits until a frame, close, or error is queued.
private final class FakeSocket: LiveSocket {
    private struct State {
        var sent: [String] = []
        var inbox: [Result<Data, any Error>] = []
        var closeInfo: (code: Int, reason: Data?)?
        var cancelled = false
        var failSends = false
    }

    private let state = Mutex(State())

    var sent: [String] { state.withLock { $0.sent } }
    var cancelled: Bool { state.withLock { $0.cancelled } }
    func push(_ frame: String) { state.withLock { $0.inbox.append(.success(Data(frame.utf8))) } }
    func pushBinary(_ frame: Data) { state.withLock { $0.inbox.append(.success(frame)) } }
    func fail(_ error: any Error, closeCode: Int? = nil, reason: Data? = nil) {
        state.withLock {
            if let closeCode { $0.closeInfo = (closeCode, reason) }
            $0.inbox.append(.failure(error))
        }
    }
    func setFailSends() { state.withLock { $0.failSends = true } }

    func send(_ text: String) async throws {
        let shouldFail = state.withLock { state in
            if state.failSends { return true }
            state.sent.append(text)
            return false
        }
        if shouldFail { throw URLError(.networkConnectionLost) }
    }

    func receive() async throws -> Data {
        while true {
            let next = state.withLock { $0.inbox.isEmpty ? nil : $0.inbox.removeFirst() }
            if let next { return try next.get() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func cancel() { state.withLock { $0.cancelled = true } }

    var closeInfo: (code: Int, reason: Data?)? { state.withLock { $0.closeInfo } }
}

@Suite struct GeminiTransportTests {
    private static let secret = "AIzaFAKE-TEST-KEY-1234567890"

    private func configuration(placement: GeminiLiveConfiguration.KeyPlacement = .header) throws -> GeminiLiveConfiguration {
        var configuration = GeminiLiveConfiguration(apiKey: APIKey(Self.secret), toolContract: try toolContractData())
        configuration.keyPlacement = placement
        return configuration
    }

    private func transport(_ socket: FakeSocket, placement: GeminiLiveConfiguration.KeyPlacement = .header) throws -> GeminiLiveTransport {
        GeminiLiveTransport(configuration: try configuration(placement: placement), makeSocket: { _ in socket })
    }

    private func collect(_ stream: AsyncStream<RealtimeInbound>, until: @escaping @Sendable (RealtimeInbound) -> Bool) async -> [RealtimeInbound] {
        var events: [RealtimeInbound] = []
        for await event in stream {
            events.append(event)
            if until(event) { break }
        }
        return events
    }

    // MARK: - Request

    @Test func defaultsUseThePlannedModelAndHeader() throws {
        let configuration = try configuration()
        #expect(configuration.model == "gemini-3.8-live")
        #expect(!configuration.model.contains("preview"))
        #expect(configuration.keyPlacement == .header)
    }

    @Test func headerPlacementKeepsTheKeyOutOfTheURL() throws {
        let request = try #require(GeminiLiveTransport.urlRequest(try configuration(placement: .header)))
        #expect(request.url?.absoluteString == "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == Self.secret)
    }

    @Test func queryPlacementIsTheDocumentedFallback() throws {
        let request = try #require(GeminiLiveTransport.urlRequest(try configuration(placement: .queryParameter)))
        #expect(request.url?.query == "key=\(Self.secret)")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == nil)
    }

    // MARK: - Connection

    @Test func setupIsTheFirstMessage() async throws {
        let socket = FakeSocket()
        let connection = try transport(socket).connect(RealtimeConnectRequest(resumeHandle: "h9", seedsHistory: false))
        defer { connection.close() }
        #expect(await eventually { socket.sent.count == 1 })

        let setup = try json(socket.sent[0])
        guard case let .object(root) = setup, case let .object(fields)? = root["setup"] else {
            Issue.record("first message was not setup")
            return
        }
        #expect(fields["model"] == "models/gemini-3.8-live")
        #expect(fields["sessionResumption"] == ["handle": "h9"])
        #expect(fields["historyConfig"] == nil)
        guard case let .object(instruction)? = fields["systemInstruction"] else {
            Issue.record("missing system instruction")
            return
        }
        #expect(instruction["parts"] == [["text": .string(SystemPrompt.text)]])
    }

    @Test func voiceReachesTheWire() async throws {
        let socket = FakeSocket()
        var configuration = try configuration()
        configuration.voiceName = "Kore"
        let connection = GeminiLiveTransport(configuration: configuration, makeSocket: { _ in socket })
            .connect(RealtimeConnectRequest(resumeHandle: nil, seedsHistory: false))
        defer { connection.close() }
        #expect(await eventually { socket.sent.count == 1 })

        guard case let .object(root) = try json(socket.sent[0]), case let .object(fields)? = root["setup"],
              case let .object(generation)? = fields["generationConfig"]
        else {
            Issue.record("first message was not setup")
            return
        }
        #expect(generation["speechConfig"] == ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": "Kore"]]])
        #expect(!socket.sent[0].contains(Self.secret))
    }

    @Test func noVoiceByDefault() async throws {
        let socket = FakeSocket()
        #expect(try configuration().voiceName == nil)
        let connection = try transport(socket).connect(RealtimeConnectRequest(resumeHandle: nil, seedsHistory: false))
        defer { connection.close() }
        #expect(await eventually { socket.sent.count == 1 })
        #expect(!socket.sent[0].contains("speechConfig"))
    }

    @Test func seedingRequestSetsHistoryConfig() async throws {
        let socket = FakeSocket()
        let connection = try transport(socket).connect(RealtimeConnectRequest(resumeHandle: nil, seedsHistory: true))
        defer { connection.close() }
        #expect(await eventually { socket.sent.count == 1 })
        #expect(socket.sent[0].contains("\"initialHistoryInClientContent\":true"))
    }

    @Test func framesBecomeEventsInTextOrBinary() async throws {
        let socket = FakeSocket()
        let connection = try transport(socket).connect(RealtimeConnectRequest(resumeHandle: nil, seedsHistory: false))
        defer { connection.close() }
        socket.push(#"{"setupComplete":{}}"#)
        socket.pushBinary(Data(#"{"serverContent":{"turnComplete":true}}"#.utf8))
        socket.push("garbage that is not JSON")
        socket.push(#"{"unknownMessage":{"a":1}}"#)
        socket.push(#"{"goAway":{"timeLeft":"5s"}}"#)

        let events = await collect(connection.inbound) { event in
            if case .goAway = event { true } else { false }
        }
        #expect(events == [.ready, .turnComplete, .goAway(secondsLeft: 5)])
    }

    @Test func outboundUsesTheWireFormat() async throws {
        let socket = FakeSocket()
        let connection = try transport(socket).connect(RealtimeConnectRequest(resumeHandle: nil, seedsHistory: false))
        defer { connection.close() }
        #expect(await eventually { socket.sent.count == 1 })

        try await connection.send(.audio(Data([1, 2, 3])))
        try await connection.send(.frame(jpeg: Data([1])))
        try await connection.send(.audioStreamEnd)
        try await connection.send(.stateBrief(brief(version: 8), seed: false))

        #expect(try json(socket.sent[1]) == ["realtimeInput": ["audio": ["mimeType": "audio/pcm;rate=16000", "data": "AQID"]]])
        #expect(try json(socket.sent[2]) == ["realtimeInput": ["video": ["mimeType": "image/jpeg", "data": "AQ=="]]])
        #expect(try json(socket.sent[3]) == ["realtimeInput": ["audioStreamEnd": true]])
        #expect(socket.sent[4].contains("clientContent"))
        #expect(socket.sent[4].contains("STATE BRIEF version=8"))
    }

    @Test func aServerCloseReportsItsCodeWithTheKeyScrubbed() async throws {
        let socket = FakeSocket()
        let connection = try transport(socket).connect(RealtimeConnectRequest(resumeHandle: nil, seedsHistory: false))
        defer { connection.close() }
        socket.fail(URLError(.networkConnectionLost), closeCode: 1008, reason: Data("bad key \(Self.secret) here".utf8))

        let events = await collect(connection.inbound) { _ in false }
        #expect(events == [.closed(.closedByServer(code: 1008, reason: "bad key [redacted] here"))])
    }

    @Test func aCutCannotLeavePartOfTheKeyBehind() {
        let socket = FakeSocket()
        socket.fail(URLError(.badURL), closeCode: 1011, reason: Data((String(repeating: "x", count: 190) + Self.secret).utf8))
        let reason = GeminiLiveConnection.reason(for: URLError(.badURL), socket: socket, apiKey: APIKey(Self.secret))
        #expect(!reason.description.contains("AIza"))
    }

    @Test func aNetworkFailureKeepsOnlyItsCode() async throws {
        let socket = FakeSocket()
        let connection = try transport(socket).connect(RealtimeConnectRequest(resumeHandle: nil, seedsHistory: false))
        defer { connection.close() }
        socket.fail(URLError(.notConnectedToInternet))
        let events = await collect(connection.inbound) { _ in false }
        #expect(events == [.closed(.networkFailure(code: URLError.notConnectedToInternet.rawValue))])
    }

    @Test func aSetupThatCannotSendEndsTheConnection() async throws {
        let socket = FakeSocket()
        socket.setFailSends()
        let connection = try transport(socket).connect(RealtimeConnectRequest(resumeHandle: nil, seedsHistory: false))
        defer { connection.close() }
        let events = await collect(connection.inbound) { _ in false }
        #expect(events == [.closed(.networkFailure(code: URLError.networkConnectionLost.rawValue))])
    }

    @Test func closeCancelsTheSocketAndEndsTheStream() async throws {
        let socket = FakeSocket()
        let connection = try transport(socket).connect(RealtimeConnectRequest(resumeHandle: nil, seedsHistory: false))
        connection.close()
        #expect(socket.cancelled)
        let events = await collect(connection.inbound) { _ in false }
        #expect(events.isEmpty)
    }

    @Test func aMissingKeyOrBadContractFailsWithoutASocket() async throws {
        let contract = try toolContractData()
        let cases = [
            GeminiLiveConfiguration(apiKey: APIKey("   "), toolContract: contract),
            GeminiLiveConfiguration(apiKey: APIKey(Self.secret), toolContract: Data("not json".utf8)),
        ]
        for configuration in cases {
            let transport = GeminiLiveTransport(configuration: configuration) { _ in
                Issue.record("should not open a socket")
                return FakeSocket()
            }
            let connection = transport.connect(RealtimeConnectRequest(resumeHandle: nil, seedsHistory: false))
            let events = await collect(connection.inbound) { _ in false }
            #expect(events == [.closed(.invalidConfiguration)])
            await #expect(throws: (any Error).self) { try await connection.send(.audioStreamEnd) }
        }
    }

    /// A whole session, from a real Gemini frame stream through to its events.
    @Test func aSessionRunsOverTheGeminiTransport() async throws {
        let socket = FakeSocket()
        let session = LiveSession(transport: try transport(socket), clock: { 7 })
        let events = EventRecorder(session.events)
        await session.sendStateBrief(brief(version: 2))
        await session.start()

        #expect(await eventually { socket.sent.count == 1 })
        #expect(socket.sent[0].contains("initialHistoryInClientContent"))
        socket.push(#"{"setupComplete":{}}"#)
        #expect(await eventually { socket.sent.count == 2 })
        #expect(socket.sent[1].contains("\"turnComplete\":true"))

        socket.push("""
        {"toolCall":{"functionCalls":[{"id":"z","name":"log_event","args":{"kind":"vomiting","state_version":2}}]}}
        """)
        #expect(await eventually { socket.sent.count == 3 })
        #expect(socket.sent[2].contains("\"toolResponse\""))
        #expect(socket.sent[2].contains("\"id\":\"z\""))
        #expect(events.proposals == [ModelProposal(action: .logEvent(.vomiting), stateVersion: 2, issuedAt: 7)])
        await session.stop()
    }
}
