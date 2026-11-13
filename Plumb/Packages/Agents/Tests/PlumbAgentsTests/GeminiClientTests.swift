import Foundation
import Testing
@testable import PlumbAgents

@Suite struct GeminiClientTests {
    private let schema = JSONSchema.object(["answer": JSONSchema.string(description: "The answer.")], required: ["answer"])

    private func client(_ transport: FakeTransport, dialect: GenerateDialect = .interactions) -> GeminiClient {
        var config = AgentsConfig()
        config.restDialect = dialect
        config.retryPause = .zero
        return GeminiClient(apiKey: secretKey, transport: transport, config: config)
    }

    private func body(of request: URLRequest) throws -> JSONValue {
        try JSONValue(parsing: try #require(request.httpBody))
    }

    // MARK: Request shape

    @Test func interactionsRequestCarriesTheKeyInAHeaderAndNeverInTheURL() async throws {
        let transport = FakeTransport([.respond(status: 200, body: interactionsBody(text: #"{"answer":"yes"}"#))])

        _ = try await client(transport).generateJSON(model: "gemini-3.8-flash", system: "Be brief.",
                                                     parts: [.text("Hello")], schema: schema, timeout: .seconds(5))

        let request = try #require(transport.requests.first)
        let url = try #require(request.url)
        #expect(url.absoluteString == "https://generativelanguage.googleapis.com/v1beta/interactions")
        #expect(url.query == nil)
        #expect(!url.absoluteString.contains(secretKey))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == secretKey)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Api-Revision") == "2026-05-20")
        #expect(!String(decoding: try #require(request.httpBody), as: UTF8.self).contains(secretKey))
    }

    @Test func interactionsBodyHoldsTheModelSystemPartsSchemaAndThinking() async throws {
        let transport = FakeTransport([.respond(status: 200, body: interactionsBody(text: "{}"))])
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])

        _ = try await client(transport).generateJSON(model: "gemini-3.8-flash", system: "Be brief.",
                                                     parts: [.jpeg(jpeg), .text("Where?")], schema: schema,
                                                     thinking: "low", timeout: .seconds(5))

        let sent = try body(of: try #require(transport.requests.first))
        #expect(sent["model"] == "gemini-3.8-flash")
        #expect(sent["system_instruction"] == "Be brief.")
        #expect(sent["store"] == false)
        #expect(sent["input"] == [
            ["type": "image", "data": .string(jpeg.base64EncodedString()), "mime_type": "image/jpeg"],
            ["type": "text", "text": "Where?"],
        ])
        #expect(sent["response_format"] == ["type": "text", "mime_type": "application/json", "schema": schema])
        #expect(sent["generation_config"] == ["thinking_level": "low"])
    }

    @Test func withoutASchemaOrThinkingThoseFieldsAreLeftOut() async throws {
        let transport = FakeTransport([.respond(status: 200, body: interactionsBody(text: "[]"))])

        _ = try await client(transport).generateJSON(model: "m", system: "s", parts: [.text("t")],
                                                     schema: nil, timeout: .seconds(5))

        let sent = try body(of: try #require(transport.requests.first))
        #expect(sent["response_format"] == nil)
        #expect(sent["generation_config"] == nil)
    }

    @Test func generateContentDialectUsesTheOlderShape() async throws {
        let answer = #"{"candidates":[{"content":{"parts":[{"text":"plan","thought":true},{"text":"{\"answer\":"},{"text":"\"yes\"}"}]},"finishReason":"STOP"}]}"#
        let transport = FakeTransport([.respond(status: 200, body: answer)])

        let data = try await client(transport, dialect: .generateContent).generateJSON(
            model: "gemini-3.8-flash", system: "Be brief.", parts: [.text("Hello"), .jpeg(Data([1, 2]))],
            schema: schema, thinking: "low", timeout: .seconds(5))

        #expect(String(decoding: data, as: UTF8.self) == #"{"answer":"yes"}"#)
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == secretKey)
        #expect(request.value(forHTTPHeaderField: "Api-Revision") == nil)
        let sent = try body(of: request)
        #expect(sent["systemInstruction"] == ["parts": [["text": "Be brief."]]])
        #expect(sent["contents"] == [[
            "role": "user",
            "parts": [["text": "Hello"], ["inlineData": ["mimeType": "image/jpeg", "data": "AQI="]]],
        ]])
        #expect(sent["generationConfig"] == [
            "responseMimeType": "application/json", "responseJsonSchema": schema,
            "thinkingConfig": ["thinkingLevel": "low"],
        ])
    }

    // MARK: Response

    @Test func returnsTheModelTextAsBytes() async throws {
        let transport = FakeTransport([.respond(status: 200, body: interactionsBody(text: #"{"answer":"yes"}"#))])

        let data = try await client(transport).generateJSON(model: "m", system: "s", parts: [.text("t")],
                                                            schema: schema, timeout: .seconds(5))

        #expect(String(decoding: data, as: UTF8.self) == #"{"answer":"yes"}"#)
    }

    @Test func anAnswerWithNoTextIsAnError() async {
        let transport = FakeTransport([.respond(status: 200, body: #"{"status":"incomplete","steps":[]}"#)])

        await #expect(throws: GeminiError.noText(detail: "status incomplete")) {
            try await client(transport).generateJSON(model: "m", system: "s", parts: [.text("t")],
                                                     schema: schema, timeout: .seconds(5))
        }
        #expect(transport.requests.count == 1)
    }

    @Test func anAnswerThatIsNotJSONIsUnreadable() async {
        let transport = FakeTransport([.respond(status: 200, body: "<html>gateway</html>")])

        await #expect(throws: GeminiError.unreadable) {
            try await client(transport).generateJSON(model: "m", system: "s", parts: [.text("t")],
                                                     schema: schema, timeout: .seconds(5))
        }
    }

    // MARK: Retry

    @Test func retriesOnceAfterA5xx() async throws {
        let transport = FakeTransport([
            .respond(status: 503, body: "busy"),
            .respond(status: 200, body: interactionsBody(text: "{}")),
        ])

        let data = try await client(transport).generateJSON(model: "m", system: "s", parts: [.text("t")],
                                                            schema: schema, timeout: .seconds(5))

        #expect(String(decoding: data, as: UTF8.self) == "{}")
        #expect(transport.requests.count == 2)
    }

    @Test func givesUpAfterTwo5xxAnswers() async {
        let transport = FakeTransport([
            .respond(status: 503, body: "busy"),
            .respond(status: 502, body: "still busy"),
            .respond(status: 200, body: interactionsBody(text: "{}")),
        ])

        await #expect(throws: GeminiError.http(status: 502, detail: "still busy")) {
            try await client(transport).generateJSON(model: "m", system: "s", parts: [.text("t")],
                                                     schema: schema, timeout: .seconds(5))
        }
        #expect(transport.requests.count == 2)
    }

    @Test func retriesOnceAfterATransportFailure() async throws {
        let transport = FakeTransport([
            .fail(URLError(.networkConnectionLost)),
            .respond(status: 200, body: interactionsBody(text: "{}")),
        ])

        _ = try await client(transport).generateJSON(model: "m", system: "s", parts: [.text("t")],
                                                     schema: schema, timeout: .seconds(5))

        #expect(transport.requests.count == 2)
    }

    @Test func neverRetriesA4xx() async {
        let transport = FakeTransport([
            .respond(status: 429, body: #"{"error":{"code":429,"message":"Slow down.","status":"RESOURCE_EXHAUSTED"}}"#),
            .respond(status: 200, body: interactionsBody(text: "{}")),
        ])

        await #expect(throws: GeminiError.http(status: 429, detail: "Slow down.")) {
            try await client(transport).generateJSON(model: "m", system: "s", parts: [.text("t")],
                                                     schema: schema, timeout: .seconds(5))
        }
        #expect(transport.requests.count == 1)
    }

    @Test func anErrorWrappedInAListIsReadTheSameWay() async {
        // The shape the interactions endpoint returned for a call without a key.
        let wrapped = #"[{"error": {"code": 403, "message": "Method doesn't allow unregistered callers.", "status": "PERMISSION_DENIED"}}]"#
        let transport = FakeTransport([.respond(status: 403, body: wrapped)])

        await #expect(throws: GeminiError.http(status: 403, detail: "Method doesn't allow unregistered callers.")) {
            try await client(transport).generateJSON(model: "m", system: "s", parts: [.text("t")],
                                                     schema: schema, timeout: .seconds(5))
        }
    }

    @Test func theTimeoutCoversTheWholeCall() async {
        let transport = FakeTransport([.hang])

        let started = SuspendingClock.now
        await #expect(throws: GeminiError.timedOut(seconds: 0.1)) {
            try await client(transport).generateJSON(model: "m", system: "s", parts: [.text("t")],
                                                     schema: schema, timeout: .milliseconds(100))
        }
        #expect(SuspendingClock.now - started < .seconds(10))
    }

    // MARK: The key never leaks

    @Test func anErrorFromARefusedCallDoesNotContainTheKey() async {
        let echo = #"{"error":{"code":400,"message":"API key \#(secretKey) is not valid. Pass a valid key \#(secretKey)."}}"#
        let transport = FakeTransport([.respond(status: 400, body: echo)])

        do {
            _ = try await client(transport).generateJSON(model: "m", system: "s", parts: [.text("t")],
                                                         schema: schema, timeout: .seconds(5))
            Issue.record("expected the call to fail")
        } catch {
            for text in [String(describing: error), error.localizedDescription, String(reflecting: error)] {
                #expect(!text.contains(secretKey))
                #expect(text.contains("[key]"))
            }
        }
    }

    @Test func anErrorFromAFailedConnectionDoesNotContainTheKey() async {
        let transport = FakeTransport([
            .fail(TalkativeError(text: "could not open https://example.test/?key=\(secretKey)")),
            .fail(TalkativeError(text: "still could not send header \(secretKey)")),
        ])

        do {
            _ = try await client(transport).generateJSON(model: "m", system: "s", parts: [.text("t")],
                                                         schema: schema, timeout: .seconds(5))
            Issue.record("expected the call to fail")
        } catch {
            #expect(!String(describing: error).contains(secretKey))
            #expect(!String(reflecting: error).contains(secretKey))
            #expect(error as? GeminiError == .transport(detail: "still could not send header [key]"))
        }
    }

    @Test func aKeyCutByTheLengthLimitLeavesNoPartBehind() async {
        // The key starts just before the cut, so cutting first would leave its first half in view.
        let padding = String(repeating: "x", count: AgentsConfig().errorDetailLimit - 10)
        let transport = FakeTransport([.respond(status: 400, body: padding + secretKey + " trailing text")])

        do {
            _ = try await client(transport).generateJSON(model: "m", system: "s", parts: [.text("t")],
                                                         schema: schema, timeout: .seconds(5))
            Issue.record("expected the call to fail")
        } catch {
            #expect(!String(describing: error).contains(secretKey.prefix(8)))
        }
    }

    @Test func onlyAShortPrefixOfAnErrorBodyIsKept() async {
        let transport = FakeTransport([.respond(status: 400, body: String(repeating: "long body ", count: 500))])

        do {
            _ = try await client(transport).generateJSON(model: "m", system: "s", parts: [.text("t")],
                                                         schema: schema, timeout: .seconds(5))
            Issue.record("expected the call to fail")
        } catch {
            #expect(String(describing: error).count < 260)
        }
    }
}
