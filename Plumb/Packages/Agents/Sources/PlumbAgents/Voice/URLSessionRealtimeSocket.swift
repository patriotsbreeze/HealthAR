import Foundation

/// A `RealtimeSocket` over `URLSessionWebSocketTask`.
///
/// The session it creates keeps this object alive until `close()` is called, so always close it.
public final class URLSessionRealtimeSocket: NSObject, RealtimeSocket, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let maxMessageBytes: Int
    /// Guards everything below. Delegate callbacks arrive on the session's own queue.
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var opening: CheckedContinuation<Void, Error>?
    private var closure: SocketClosure?

    /// - Parameters:
    ///   - request: the handshake request, including any headers.
    ///   - maxMessageBytes: the largest single message accepted from the far end.
    public init(request: URLRequest, maxMessageBytes: Int = AgentsConfig().socketMaxMessageBytes) {
        self.request = request
        self.maxMessageBytes = maxMessageBytes
    }

    /// Opens the socket and returns once the handshake has been accepted.
    public func connect() async throws {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = maxMessageBytes
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock {
                self.session = session
                self.task = task
                self.opening = continuation
            }
            task.resume()
        }
    }

    /// Sends one text frame.
    public func send(text: String) async throws {
        guard let task = lock.withLock({ self.task }) else { throw URLError(.networkConnectionLost) }
        try await task.send(.string(text))
    }

    /// Every frame from the far end, in order. Call once, after `connect()`.
    public func frames() -> AsyncThrowingStream<SocketFrame, Error> {
        AsyncThrowingStream { continuation in
            guard let task = lock.withLock({ self.task }) else {
                continuation.finish(throwing: URLError(.networkConnectionLost))
                return
            }
            let reader = Task { [weak self] in
                do {
                    while true {
                        switch try await task.receive() {
                        case .string(let text): continuation.yield(.text(text))
                        case .data(let data): continuation.yield(.binary(data))
                        @unknown default: break
                        }
                    }
                } catch {
                    // When the far end closed with a code, that says more than the read error does.
                    let closure = self?.lock.withLock { self?.closure }
                    continuation.finish(throwing: closure ?? error)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    /// Closes the socket and releases the session. Safe to call more than once.
    public func close() {
        let (session, task) = lock.withLock { () -> (URLSession?, URLSessionWebSocketTask?) in
            defer {
                self.session = nil
                self.task = nil
            }
            return (self.session, self.task)
        }
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        finishOpening(with: .failure(URLError(.cancelled)))
    }

    // MARK: - URLSessionWebSocketDelegate

    /// The handshake was accepted.
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {
        finishOpening(with: .success(()))
    }

    /// The far end closed the socket. Its code and reason are kept for whoever is reading frames.
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let text = reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        lock.withLock { closure = SocketClosure(code: closeCode.rawValue, reason: text) }
    }

    /// The connection ended. If the handshake was still pending, this is what fails it.
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finishOpening(with: .failure(error ?? URLError(.networkConnectionLost)))
    }

    // MARK: - Private

    /// Resumes whoever is waiting in `connect()`, exactly once.
    private func finishOpening(with result: Result<Void, Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { opening = nil }
            return opening
        }
        waiting?.resume(with: result)
    }
}
