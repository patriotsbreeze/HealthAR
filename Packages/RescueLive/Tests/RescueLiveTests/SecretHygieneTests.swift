import Foundation
import RescueCore
import Testing
@testable import RescueLive

/// The key must not appear in anything that gets formatted. The URL can hold it too, so an error
/// that keeps its URL fails here even when the key was sent as a header.
@Suite struct SecretHygieneTests {
    private static let secret = "AIzaFAKE-TEST-KEY-1234567890"
    private static let key = APIKey(secret)

    private func everyFormat(of value: Any) -> [String] {
        var dumped = ""
        dump(value, to: &dumped)
        return [String(describing: value), String(reflecting: value), "\(value)", dumped]
    }

    private func expectClean(_ value: Any, sourceLocation: SourceLocation = #_sourceLocation) {
        for text in everyFormat(of: value) {
            #expect(!text.contains(Self.secret), "key leaked in: \(text.prefix(80))", sourceLocation: sourceLocation)
        }
    }

    @Test func theKeyItselfFormatsAsRedacted() {
        expectClean(Self.key)
        #expect("\(Self.key)" == "[redacted]")
    }

    @Test func holdersOfTheKeyDoNotShowIt() throws {
        let configuration = GeminiLiveConfiguration(apiKey: Self.key, toolContract: try toolContractData())
        expectClean(configuration)
        expectClean(GeminiLiveTransport(configuration: configuration))
        expectClean(Auditor(apiKey: Self.key))
        expectClean(GeminiLocator(apiKey: Self.key))
        expectClean(GeminiLiveTransport.self)
    }

    @Test func everyDisconnectReasonFormatsClean() {
        let socket = URLErrorSocket()
        let urlError = URLError(.cannotConnectToHost, userInfo: [
            NSURLErrorFailingURLErrorKey: URL(string: "wss://example.test/ws?key=\(Self.secret)")!,
            NSLocalizedDescriptionKey: "failed at wss://example.test/ws?key=\(Self.secret)",
        ])
        // The error really does carry the key, which is why it must not be kept.
        #expect("\(urlError)".contains(Self.secret))

        let fromError = GeminiLiveConnection.reason(for: urlError, socket: socket, apiKey: Self.key)
        expectClean(fromError)
        #expect(fromError == .networkFailure(code: URLError.cannotConnectToHost.rawValue))

        socket.closeInfo = (1008, Data("key \(Self.secret) rejected".utf8))
        let fromClose = GeminiLiveConnection.reason(for: urlError, socket: socket, apiKey: Self.key)
        expectClean(fromClose)

        let reasons: [LiveDisconnectReason] = [
            .stopped, .goAway, .setupTimeout, .sendFailed, .invalidConfiguration,
            .networkFailure(code: nil), .networkFailure(code: -1009),
            .closedByServer(code: 1011, reason: nil), fromError, fromClose,
        ]
        for reason in reasons {
            expectClean(reason)
            expectClean(LiveEvent.disconnected(reason))
            expectClean(RealtimeInbound.closed(reason))
        }
    }

    @Test func configurationErrorsAreClean() {
        expectClean(LiveConfigurationError.invalidToolContract)
    }

    @Test func aFailedSessionEmitsNoKey() async throws {
        let contract = try toolContractData()
        var configuration = GeminiLiveConfiguration(apiKey: Self.key, toolContract: contract)
        configuration.keyPlacement = .queryParameter
        let socket = URLErrorSocket()
        let transport = GeminiLiveTransport(configuration: configuration) { _ in socket }

        var settings = LiveSession.Configuration()
        settings.backoff = [60]
        let session = LiveSession(transport: transport, configuration: settings, clock: { 0 })
        let events = EventRecorder(session.events)
        socket.failure = URLError(.cannotConnectToHost, userInfo: [
            NSLocalizedDescriptionKey: "failed at wss://example.test/ws?key=\(Self.secret)",
        ])
        await session.start()
        #expect(await eventually { !events.disconnects.isEmpty })
        await session.stop()
        for event in events.all { expectClean(event) }
    }

    @Test func restFailuresReturnNilAndNoText() async {
        let http = StubHTTP(failure: URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: Self.secret]))
        #expect(await Auditor(apiKey: Self.key, http: http.client).audit(transcript: "x", brief: brief()) == nil)
        #expect(await GeminiLocator(apiKey: Self.key, http: http.client).locate(jpeg: Data([1]), label: "aed") == nil)
    }

    @Test func restRequestsCarryTheKeyOnlyInTheHeader() async throws {
        let http = StubHTTP(body: "{}")
        _ = await Auditor(apiKey: Self.key, http: http.client).audit(transcript: "x", brief: brief())
        _ = await GeminiLocator(apiKey: Self.key, http: http.client).locate(jpeg: Data([1]), label: "aed")
        #expect(http.seen.count == 2)
        for request in http.seen {
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == Self.secret)
            #expect(request.url?.absoluteString.contains(Self.secret) == false)
            let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
            #expect(!body.contains(Self.secret))
        }
    }

    /// Nothing in this package may log, since a log line is how URLs and keys escape.
    @Test func sourcesContainNoLogging() throws {
        let sources = repoRoot().appendingPathComponent("Packages/RescueLive/Sources/RescueLive")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        let banned = ["print(", "debugPrint(", "NSLog(", "os_log(", "Logger(", "dump("]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in banned {
                #expect(!text.contains(word), "\(file.lastPathComponent) contains \(word)")
            }
        }
    }

    @Test func sourcesHoldNoRealEmergencyNumberOrDialURL() throws {
        let sources = repoRoot().appendingPathComponent("Packages/RescueLive/Sources/RescueLive")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("tel:"))
            #expect(!text.contains("911"))
        }
    }

    @Test func noPreviewModelsAreUsed() {
        for model in [GeminiLiveConfiguration.defaultModel, Auditor.model, GeminiLocator.model] {
            #expect(!model.contains("preview"))
        }
        #expect(GeminiLiveConfiguration.defaultModel == "gemini-3.8-live")
        #expect(GeminiLocator.model == "gemini-3.8-flash")
        #expect(Auditor.model == "gemini-3.5-flash-lite")
    }
}

/// A socket whose `receive` fails with a chosen error.
private final class URLErrorSocket: LiveSocket, @unchecked Sendable {
    var closeInfo: (code: Int, reason: Data?)?
    var failure: URLError = URLError(.unknown)

    func send(_ text: String) async throws {}
    func receive() async throws -> Data { throw failure }
    func cancel() {}
}
