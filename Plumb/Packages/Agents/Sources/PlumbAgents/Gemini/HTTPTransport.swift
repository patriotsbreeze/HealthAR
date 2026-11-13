import Foundation

/// The one place an HTTPS request leaves the app. Small on purpose, so tests can replace it.
public protocol HTTPTransport: Sendable {
    /// Sends the request and returns the body with the HTTP response.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Sends requests with a `URLSession` that keeps no cookies, cache or credentials on disk.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// Creates a transport with its own ephemeral session.
    public init() {
        session = URLSession(configuration: .ephemeral)
    }

    /// Sends the request over the network and returns the body with the HTTP response.
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
