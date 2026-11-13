import Foundation
@testable import RescueCore
import Synchronization
import Testing
@testable import RescueLive

func repoRoot(file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent() // RescueLiveTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // RescueLive
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repo root
}

func toolContractData() throws -> Data {
    try Data(contentsOf: repoRoot().appendingPathComponent("contracts/tools.v1.json"))
}

/// GEMINI_VOICE in Config/Demo.xcconfig: the voice the phrase clips are rendered in and the app
/// gives both sessions. Read as the README's awk reads the key: the line's value after `=`.
func configuredVoice() -> String? {
    guard let text = try? String(contentsOf: repoRoot().appendingPathComponent("Config/Demo.xcconfig"), encoding: .utf8) else { return nil }
    var voice: String?
    for line in text.split(separator: "\n") {
        guard let match = line.wholeMatch(of: /GEMINI_VOICE[ \t]*=[ \t]*(.*?)\s*/) else { continue }
        voice = match.1.isEmpty ? nil : String(match.1)
    }
    return voice
}

func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

func parsed(_ message: LiveClientMessage) throws -> JSONValue {
    try json(try message.encodedText())
}

func decodeServer(_ text: String) throws -> LiveServerMessage {
    try #require(GeminiCodec.decode(Data(text.utf8)))
}

func brief(version: Int = 1, state: String = "intake_responsive", mayspeak: Bool = true) -> StateBrief {
    StateBrief(
        version: version,
        stateID: state,
        allowedSay: ["keep_going"],
        modelSpeechOpen: mayspeak,
        recentlyPlayed: [],
        resources: [],
        elapsedSeconds: 3
    )
}

/// A clock tests can move by hand.
final class TestClock: Sendable {
    private let time: Mutex<TimeInterval>

    init(_ start: TimeInterval = 1000) {
        time = Mutex(start)
    }

    var now: TimeInterval { time.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { time.withLock { $0 += seconds } }
    var reader: @Sendable () -> TimeInterval { { [self] in now } }
}

/// Polls until the condition holds. Real time, so the wait is generous and rarely used in full.
func eventually(
    timeout: Duration = .seconds(5),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

/// Collects everything a session emits.
final class EventRecorder: Sendable {
    private let items = Mutex<[LiveEvent]>([])

    init(_ stream: AsyncStream<LiveEvent>) {
        Task { [self] in
            for await event in stream { items.withLock { $0.append(event) } }
        }
    }

    var all: [LiveEvent] { items.withLock { $0 } }
    func contains(_ event: LiveEvent) -> Bool { all.contains(event) }
    var proposals: [ModelProposal] {
        all.compactMap { if case let .proposal(value) = $0 { value } else { nil } }
    }
    var disconnects: [LiveDisconnectReason] {
        all.compactMap { if case let .disconnected(value) = $0 { value } else { nil } }
    }
    func timing(_ metric: LiveTimingMetric) -> TimeInterval? {
        all.compactMap { if case let .timing(found, seconds) = $0, found == metric { seconds } else { nil } }.last
    }
}

/// An HTTP closure that records requests and replays one response.
final class StubHTTP: Sendable {
    private let requests = Mutex<[URLRequest]>([])
    private let body: Data
    private let status: Int
    private let failure: URLError?

    init(body: String, status: Int = 200) {
        self.body = Data(body.utf8)
        self.status = status
        failure = nil
    }

    init(failure: URLError) {
        body = Data()
        status = 0
        self.failure = failure
    }

    var seen: [URLRequest] { requests.withLock { $0 } }

    var client: HTTPClient {
        { [self] request in
            requests.withLock { $0.append(request) }
            if let failure { throw failure }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }
}

/// Wraps model text the way generateContent does.
func candidateJSON(text: String) throws -> String {
    let envelope: JSONValue = ["candidates": [["content": ["role": "model", "parts": [["text": .string(text)]]]]]]
    return String(decoding: try envelope.encoded(), as: UTF8.self)
}
