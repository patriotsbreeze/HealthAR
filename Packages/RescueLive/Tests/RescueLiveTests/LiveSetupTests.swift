import Foundation
import Testing
@testable import RescueLive

@Suite struct LiveSetupTests {
    private func setup(resumeHandle: String? = nil, seedsHistory: Bool = false, voiceName: String? = nil) throws -> [String: JSONValue] {
        let setup = LiveSetup(
            model: "gemini-3.8-live",
            systemInstruction: "be brief",
            functionDeclarations: try LiveSetup.functionDeclarations(fromContract: try toolContractData()),
            resumeHandle: resumeHandle,
            seedsHistory: seedsHistory,
            voiceName: voiceName
        )
        guard case let .object(root) = try parsed(.setup(setup)), case let .object(fields)? = root["setup"] else {
            throw LiveConfigurationError.invalidToolContract
        }
        return fields
    }

    @Test func requiredFields() throws {
        let fields = try setup()
        #expect(fields["model"] == "models/gemini-3.8-live")
        #expect(fields["generationConfig"] == [
            "responseModalities": ["AUDIO"],
            "mediaResolution": "MEDIA_RESOLUTION_LOW",
        ])
        #expect(fields["systemInstruction"] == ["parts": [["text": "be brief"]]])
        #expect(fields["contextWindowCompression"] == ["slidingWindow": [:]])
        #expect(fields["sessionResumption"] == [:])
        #expect(fields["inputAudioTranscription"] == [:])
        #expect(fields["outputAudioTranscription"] == [:])
    }

    @Test func noThinkingOrProactivityFields() throws {
        // The capabilities page says 3.8 Live rejects these. Neither is set anywhere.
        let fields = try setup()
        #expect(fields["proactivity"] == nil)
        guard case let .object(config)? = fields["generationConfig"] else {
            Issue.record("missing generationConfig")
            return
        }
        #expect(config["thinkingConfig"] == nil)
    }

    /// The path the Live API reference gives for a prebuilt voice, and nowhere else in setup.
    @Test func voiceGoesUnderGenerationConfig() throws {
        let fields = try setup(voiceName: "Kore")
        #expect(fields["generationConfig"] == [
            "responseModalities": ["AUDIO"],
            "mediaResolution": "MEDIA_RESOLUTION_LOW",
            "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": "Kore"]]],
        ])
        #expect(fields["speechConfig"] == nil)
        #expect(fields["voiceConfig"] == nil)
    }

    /// No voice, no speechConfig, so the model keeps its default and the setup is as it was.
    @Test(arguments: [nil, ""] as [String?])
    func noVoiceNoSpeechConfig(_ voiceName: String?) throws {
        let fields = try setup(voiceName: voiceName)
        guard case let .object(config)? = fields["generationConfig"] else {
            Issue.record("missing generationConfig")
            return
        }
        #expect(config["speechConfig"] == nil)
        #expect(config.keys.sorted() == ["mediaResolution", "responseModalities"])
    }

    @Test func theAppsVoiceSettingIsAPrebuiltName() throws {
        let voice = try #require(configuredVoice(), "GEMINI_VOICE in Config/Demo.xcconfig")
        #expect(voice.wholeMatch(of: /[A-Z][a-z]{2,20}/) != nil, "\(voice)")
    }

    @Test func resumeHandleIsPassed() throws {
        #expect(try setup(resumeHandle: "h1")["sessionResumption"] == ["handle": "h1"])
    }

    @Test func historyConfigOnlyWhenSeeding() throws {
        #expect(try setup()["historyConfig"] == nil)
        #expect(try setup(seedsHistory: true)["historyConfig"] == ["initialHistoryInClientContent": true])
    }

    @Test func toolsComeFromTheContractWithCamelCaseWrapper() throws {
        let fields = try setup()
        guard case let .array(tools)? = fields["tools"], tools.count == 1,
              case let .object(tool) = tools[0],
              case let .array(declarations)? = tool["functionDeclarations"]
        else {
            Issue.record("unexpected tools shape")
            return
        }
        let names = declarations.compactMap { declaration -> String? in
            guard case let .object(item) = declaration, case let .string(name)? = item["name"] else { return nil }
            return name
        }
        #expect(names == ["report_finding", "report_resources", "say", "locate_object", "log_event", "report_scene"])
    }

    @Test func everyFunctionIsNonBlockingWhateverTheFileSays() throws {
        let contract = #"{"function_declarations":[{"name":"a"},{"name":"b","behavior":"BLOCKING"}]}"#
        let declarations = try LiveSetup.functionDeclarations(fromContract: Data(contract.utf8))
        #expect(declarations == [
            ["name": "a", "behavior": "NON_BLOCKING"],
            ["name": "b", "behavior": "NON_BLOCKING"],
        ])
    }

    @Test(arguments: [
        "", "not json", "[]", "{}", #"{"function_declarations":[]}"#,
        #"{"function_declarations":"x"}"#, #"{"function_declarations":[{"description":"no name"}]}"#,
        #"{"function_declarations":[7]}"#,
    ])
    func aBadContractIsAnErrorAndNotACrash(_ contract: String) {
        #expect(throws: LiveConfigurationError.invalidToolContract) {
            try LiveSetup.functionDeclarations(fromContract: Data(contract.utf8))
        }
    }
}
