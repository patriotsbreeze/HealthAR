import Foundation
import Synchronization

/// A scripted transport for tests and rehearsal. Records what was sent and plays what it is told.
public final class MockTransport: RealtimeTransport {
    private struct State {
        var requests: [RealtimeConnectRequest] = []
        var sent: [RealtimeOutbound] = []
        var connections: [MockConnection] = []
        var sendsFail = false
        var sendsHeld = false
    }

    private let state = Mutex(State())

    public init() {}

    public func connect(_ request: RealtimeConnectRequest) -> any RealtimeConnection {
        let connection = MockConnection(owner: self)
        state.withLock {
            $0.requests.append(request)
            $0.connections.append(connection)
        }
        return connection
    }

    public var requests: [RealtimeConnectRequest] { state.withLock { $0.requests } }
    public var sent: [RealtimeOutbound] { state.withLock { $0.sent } }
    public var closedCount: Int { state.withLock { $0.connections.filter(\.isClosed).count } }

    /// Delivers to the newest connection.
    public func emit(_ message: RealtimeInbound) {
        state.withLock { $0.connections.last }?.emit(message)
    }

    /// Delivers to one connection by its order of creation.
    public func emit(_ message: RealtimeInbound, toConnection index: Int) {
        state.withLock { $0.connections[index] }.emit(message)
    }

    public func setSendsFail(_ fail: Bool) { state.withLock { $0.sendsFail = fail } }
    public func setSendsHeld(_ held: Bool) { state.withLock { $0.sendsHeld = held } }
    public func clearSent() { state.withLock { $0.sent = [] } }

    fileprivate func record(_ message: RealtimeOutbound) async throws {
        while state.withLock({ $0.sendsHeld }) {
            try await Task.sleep(for: .milliseconds(2))
        }
        let shouldFail = state.withLock { state in
            if state.sendsFail { return true }
            state.sent.append(message)
            return false
        }
        if shouldFail { throw URLError(.networkConnectionLost) }
    }
}

private final class MockConnection: RealtimeConnection {
    let inbound: AsyncStream<RealtimeInbound>
    private let continuation: AsyncStream<RealtimeInbound>.Continuation
    private let owner: MockTransport
    private let closed = Mutex(false)

    init(owner: MockTransport) {
        self.owner = owner
        (inbound, continuation) = AsyncStream.makeStream(of: RealtimeInbound.self, bufferingPolicy: .bufferingNewest(512))
    }

    var isClosed: Bool { closed.withLock { $0 } }

    func emit(_ message: RealtimeInbound) {
        continuation.yield(message)
        if case .closed = message { continuation.finish() }
    }

    func send(_ message: RealtimeOutbound) async throws {
        try await owner.record(message)
    }

    func close() {
        closed.withLock { $0 = true }
        continuation.finish()
    }
}
