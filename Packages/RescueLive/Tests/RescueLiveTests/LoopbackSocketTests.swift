import Foundation
import Network
import Synchronization
import Testing
@testable import RescueLive

/// A WebSocket server on the loopback interface, so the real `URLSessionWebSocketTask` adapter can
/// be checked with no outside network. It proves the socket mechanics only, not Gemini's behavior.
private final class LoopbackServer: Sendable {
    private struct State {
        var headers: [String: String] = [:]
        var received: [String] = []
        var connection: NWConnection?
    }

    private final class Box: Sendable {
        let state = Mutex(State())
    }

    private let box = Box()
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback.server")

    init() throws {
        let options = NWProtocolWebSocket.Options()
        options.setClientRequestHandler(queue) { [box] _, headers in
            box.state.withLock { current in
                for header in headers { current.headers[header.name.lowercased()] = header.value }
            }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.box.state.withLock { $0.connection = connection }
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }
        listener.start(queue: queue)
    }

    func port() async -> UInt16? {
        for _ in 0..<500 {
            if let port = listener.port?.rawValue, port != 0 { return port }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }

    var headers: [String: String] { box.state.withLock { $0.headers } }
    var received: [String] { box.state.withLock { $0.received } }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data, !data.isEmpty {
                self.box.state.withLock { $0.received.append(String(decoding: data, as: UTF8.self)) }
            }
            self.receive(on: connection)
        }
    }

    func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        box.state.withLock { $0.connection }?.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// Closes with code 1008.
    func closeWithPolicyViolation(reason: String) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.policyViolation)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        box.state.withLock { $0.connection }?.send(content: Data(reason.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    func dropAbruptly() {
        box.state.withLock { $0.connection }?.forceCancel()
    }

    func stop() {
        box.state.withLock { $0.connection }?.forceCancel()
        listener.cancel()
    }
}

@Suite(.serialized) struct LoopbackSocketTests {
    private static let secret = "AIzaFAKE-TEST-KEY-1234567890"

    private func makeTransport(port: UInt16) throws -> GeminiLiveTransport {
        let configuration = GeminiLiveConfiguration(apiKey: APIKey(Self.secret), toolContract: try toolContractData())
        let session = URLSession(configuration: .ephemeral)
        return GeminiLiveTransport(configuration: configuration) { original in
            // Keeps the headers the transport set, and only changes where the socket goes.
            var request = original
            request.url = URL(string: "ws://127.0.0.1:\(port)/")
            return URLSessionLiveSocket(session: session, request: request)
        }
    }

    @Test func theRealSocketCarriesAWholeSession() async throws {
        let server = try LoopbackServer()
        defer { server.stop() }
        let port = try #require(await server.port())

        let session = LiveSession(transport: try makeTransport(port: port), clock: { 1 })
        let events = EventRecorder(session.events)
        await session.start()

        // Setup is queued before the handshake finishes and arrives first.
        #expect(await eventually { server.received.count == 1 })
        #expect(server.received.first?.hasPrefix(#"{"setup":"#) == true)
        #expect(server.headers["x-goog-api-key"] == Self.secret)

        // The docs don't state the frame type, so both kinds are exercised.
        server.send(Data(#"{"setupComplete":{}}"#.utf8), opcode: .binary)
        #expect(await eventually { events.contains(.connected(resumed: false)) })

        server.send(Data(#"{"serverContent":{"turnComplete":true}}"#.utf8), opcode: .text)
        #expect(await eventually { events.contains(.turnComplete) })

        await session.sendAudio(Data([1, 2, 3]))
        #expect(await eventually { server.received.count == 2 })
        #expect(server.received.last?.contains(#""audio/pcm;rate=16000""#) == true)

        await session.stop()
    }

    @Test func aServerCloseSurfacesItsCodeWithTheKeyScrubbed() async throws {
        let server = try LoopbackServer()
        defer { server.stop() }
        let port = try #require(await server.port())

        var settings = LiveSession.Configuration()
        settings.backoff = [60]
        let session = LiveSession(transport: try makeTransport(port: port), configuration: settings, clock: { 1 })
        let events = EventRecorder(session.events)
        await session.start()
        #expect(await eventually { server.received.count == 1 })
        server.send(Data(#"{"setupComplete":{}}"#.utf8), opcode: .binary)
        #expect(await eventually { events.contains(.connected(resumed: false)) })

        server.closeWithPolicyViolation(reason: "bad \(Self.secret)")
        #expect(await eventually { !events.disconnects.isEmpty })
        #expect(events.disconnects.first == .closedByServer(code: 1008, reason: "bad [redacted]"))
        await session.stop()
    }

    @Test func anAbruptDropBecomesAnEventWithNoText() async throws {
        let server = try LoopbackServer()
        defer { server.stop() }
        let port = try #require(await server.port())

        var settings = LiveSession.Configuration()
        settings.backoff = [60]
        let session = LiveSession(transport: try makeTransport(port: port), configuration: settings, clock: { 1 })
        let events = EventRecorder(session.events)
        await session.start()
        #expect(await eventually { server.received.count == 1 })
        server.send(Data(#"{"setupComplete":{}}"#.utf8), opcode: .binary)
        #expect(await eventually { events.contains(.connected(resumed: false)) })

        server.dropAbruptly()
        #expect(await eventually { !events.disconnects.isEmpty })
        for reason in events.disconnects { #expect(!"\(reason)".contains(Self.secret)) }
        await session.stop()
    }

    @Test func nothingListeningBecomesAnEventAndNotAnError() async throws {
        // A port nothing is bound to, since the server below is stopped before use.
        let server = try LoopbackServer()
        let port = try #require(await server.port())
        server.stop()
        try await Task.sleep(for: .milliseconds(20))

        var settings = LiveSession.Configuration()
        settings.backoff = [60]
        let session = LiveSession(transport: try makeTransport(port: port), configuration: settings, clock: { 1 })
        let events = EventRecorder(session.events)
        await session.start()
        #expect(await eventually { !events.disconnects.isEmpty })
        for reason in events.disconnects { #expect(!"\(reason)".contains(Self.secret)) }
        await session.stop()
    }
}
