import Foundation

/// One message on a socket.
public enum SocketFrame: Sendable, Equatable {
    /// A text frame.
    case text(String)
    /// A binary frame.
    case binary(Data)
}

/// The far end closed the socket, with the code and reason it gave.
public struct SocketClosure: Error, Equatable, Sendable {
    /// The WebSocket close code.
    public var code: Int
    /// The reason text the far end sent, which may be empty.
    public var reason: String

    /// Creates a closure with the code and reason the far end gave.
    public init(code: Int, reason: String) {
        self.code = code
        self.reason = reason
    }
}

/// A two-way message socket. Small on purpose, so tests can script the far end.
public protocol RealtimeSocket: Sendable {
    /// Opens the socket. Returns once it is open, or throws.
    func connect() async throws
    /// Sends one text frame.
    func send(text: String) async throws
    /// Every frame from the far end, in order. The stream ends when the socket closes, throwing
    /// `SocketClosure` when the far end gave a close code.
    func frames() -> AsyncThrowingStream<SocketFrame, Error>
    /// Closes the socket. Safe to call more than once.
    func close()
}

/// Makes a socket for a handshake request. The request carries the URL and the key header.
public typealias RealtimeSocketFactory = @Sendable (URLRequest) -> any RealtimeSocket
