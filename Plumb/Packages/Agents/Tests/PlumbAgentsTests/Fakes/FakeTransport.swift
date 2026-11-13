import Foundation
@testable import PlumbAgents

/// An in-memory `HTTPTransport` that plays back a script and remembers every request.
final class FakeTransport: HTTPTransport, Sendable {
    enum Step: Sendable {
        case respond(status: Int, body: String)
        case fail(any Error)
        /// Never answers until cancelled.
        case hang
    }

    private let steps: Locked<[Step]>
    private let seen = Locked<[URLRequest]>([])

    init(_ steps: [Step]) {
        self.steps = Locked(steps)
    }

    var requests: [URLRequest] { seen.current }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        seen.with { $0.append(request) }
        let step = steps.with { $0.isEmpty ? Step.respond(status: 500, body: "script ran out") : $0.removeFirst() }
        switch step {
        case .respond(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        case .fail(let error):
            throw error
        case .hang:
            try await Task.sleep(for: .seconds(60))
            throw URLError(.timedOut)
        }
    }
}

/// An error whose description carries whatever text a test wants to see scrubbed.
struct TalkativeError: Error, LocalizedError {
    var text: String
    var errorDescription: String? { text }
}

/// A successful interactions response holding one piece of model text.
func interactionsBody(text: String) -> String {
    let value: JSONValue = [
        "id": "v1_test", "object": "interaction", "status": "completed",
        "steps": [
            ["type": "thought", "signature": "abc"],
            ["type": "model_output", "content": [["type": "text", "text": .string(text)]]],
        ],
    ]
    return String(decoding: try! value.encoded(), as: UTF8.self)
}
