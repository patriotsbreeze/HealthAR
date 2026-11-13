import Foundation
@testable import PlumbAgents

/// A `RealtimeSocket` whose far end is driven by the test.
final class ScriptedSocket: RealtimeSocket, Sendable {
    private let sentTexts = Locked<[String]>([])
    private let closedFlag = Locked(false)
    private let connectFailure: (any Error)?
    private let stream: AsyncThrowingStream<SocketFrame, Error>
    private let feed: AsyncThrowingStream<SocketFrame, Error>.Continuation

    /// - Parameter connectFailure: when set, `connect()` throws it.
    init(connectFailure: (any Error)? = nil) {
        self.connectFailure = connectFailure
        (stream, feed) = AsyncThrowingStream<SocketFrame, Error>.makeStream()
    }

    // MARK: RealtimeSocket

    func connect() async throws {
        if let connectFailure { throw connectFailure }
    }

    func send(text: String) async throws {
        sentTexts.with { $0.append(text) }
    }

    func frames() -> AsyncThrowingStream<SocketFrame, Error> { stream }

    func close() {
        closedFlag.with { $0 = true }
        feed.finish()
    }

    // MARK: Test controls

    /// Everything the session sent, parsed, oldest first.
    var sent: [JSONValue] {
        sentTexts.current.map { try! JSONValue(parsing: Data($0.utf8)) }
    }

    var isClosed: Bool { closedFlag.current }

    func serverSends(_ json: String, asBinary: Bool = false) {
        feed.yield(asBinary ? .binary(Data(json.utf8)) : .text(json))
    }

    func serverCloses(code: Int, reason: String) {
        feed.finish(throwing: SocketClosure(code: code, reason: reason))
    }

    /// Waits until at least `count` messages have been sent, then returns them all.
    func waitForSent(_ count: Int) async -> [JSONValue] {
        _ = await eventually { self.sentTexts.current.count >= count }
        return sent
    }
}

/// Collects a session's events as they arrive, so a test can wait for one.
final class EventLog: Sendable {
    private let events = Locked<[VoiceEvent]>([])

    init(_ stream: AsyncStream<VoiceEvent>) {
        let events = self.events
        Task {
            for await event in stream {
                events.with { $0.append(event) }
            }
        }
    }

    var all: [VoiceEvent] { events.current }

    /// Waits until the event has arrived. Returns whether it did.
    func waitFor(_ event: VoiceEvent) async -> Bool {
        await eventually { self.events.current.contains(event) }
    }

    /// Waits until some event matches. Returns the first that does.
    func waitForFirst(where matches: @escaping @Sendable (VoiceEvent) -> Bool) async -> VoiceEvent? {
        _ = await eventually { self.events.current.contains(where: matches) }
        return events.current.first(where: matches)
    }
}
