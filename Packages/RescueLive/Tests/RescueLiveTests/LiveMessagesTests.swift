import Foundation
import RescueCore
import Testing
@testable import RescueLive

@Suite struct ClientMessageTests {
    @Test func realtimeAudio() throws {
        let value = try parsed(.realtimeAudio(pcm16k: Data([1, 2, 3])))
        #expect(value == ["realtimeInput": ["audio": ["mimeType": "audio/pcm;rate=16000", "data": "AQID"]]])
    }

    @Test func realtimeVideoIsAJPEG() throws {
        let value = try parsed(.realtimeVideo(jpeg: Data([255, 216])))
        #expect(value == ["realtimeInput": ["video": ["mimeType": "image/jpeg", "data": "/9g="]]])
    }

    @Test func base64SlashesAreNotEscaped() throws {
        let text = try LiveClientMessage.realtimeVideo(jpeg: Data([255, 255, 255])).encodedText()
        #expect(text.contains("////"))
    }

    @Test func audioStreamEnd() throws {
        #expect(try parsed(.audioStreamEnd) == ["realtimeInput": ["audioStreamEnd": true]])
    }

    @Test func clientContent() throws {
        let value = try parsed(.clientContent(turns: [LiveTextTurn(role: "user", text: "hello")], turnComplete: false))
        #expect(value == ["clientContent": [
            "turns": [["role": "user", "parts": [["text": "hello"]]]],
            "turnComplete": false,
        ]])
    }

    @Test func receivedToolResponseIsSilentAndMatchesItsCall() throws {
        let response = ToolResponse(id: "call-7", name: "say", status: .received, reason: nil)
        let value = try parsed(.toolResponse([response]))

        guard case let .object(root) = value,
              case let .object(tool)? = root["toolResponse"],
              case let .array(list)? = tool["functionResponses"],
              case let .object(first)? = list.first,
              case let .object(body)? = first["response"]
        else {
            Issue.record("unexpected shape")
            return
        }
        #expect(first["id"] == "call-7")
        #expect(first["name"] == "say")
        #expect(first["scheduling"] == "SILENT")
        #expect(body["status"] == "received")
        #expect(body["scheduling"] == "SILENT")
        #expect(body["retryable"] == false)
        #expect(body["reason"] == nil)
    }

    @Test func rejectedToolResponseCarriesItsReason() throws {
        let response = ToolResponse(id: "x", name: "nope", status: .rejected, reason: .unknownTool)
        let text = try LiveClientMessage.toolResponse([response]).encodedText()
        #expect(text.contains("\"status\":\"rejected\""))
        #expect(text.contains("\"reason\":\"unknown_tool\""))
    }

    @Test func stateBriefTextIsIsolatedInOneFunction() throws {
        let later = GeminiCodec.stateBriefMessage(brief(version: 4), seed: false)
        guard case let .clientContent(turns, turnComplete) = later else {
            Issue.record("expected client content")
            return
        }
        #expect(!turnComplete)
        #expect(turns.first?.role == "user")
        #expect(turns.first?.text.hasPrefix("STATE BRIEF version=4") == true)

        guard case let .clientContent(_, seedComplete) = GeminiCodec.stateBriefMessage(brief(), seed: true) else {
            Issue.record("expected client content")
            return
        }
        #expect(seedComplete)
    }
}

/// Fixtures follow the field names on the Live API reference page.
@Suite struct ServerMessageTests {
    @Test func setupComplete() throws {
        #expect(GeminiCodec.inbound(from: try decodeServer(#"{"setupComplete":{}}"#)) == [.ready])
    }

    @Test func modelAudioFromInlineData() throws {
        let message = try decodeServer("""
        {"serverContent":{"modelTurn":{"role":"model","parts":[
          {"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AQID"}}
        ]}}}
        """)
        #expect(GeminiCodec.inbound(from: message) == [.audio(Data([1, 2, 3]))])
    }

    @Test func oneEventCanCarryManyParts() throws {
        let message = try decodeServer("""
        {"serverContent":{
          "modelTurn":{"parts":[
            {"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AQ=="}},
            {"text":"a thought"},
            {"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"Ag=="}}
          ]},
          "inputTranscription":{"text":"he is gasping"},
          "outputTranscription":{"text":"stay with me"},
          "generationComplete":true,
          "turnComplete":true,
          "interactionStatus":"IDLE"
        },"usageMetadata":{"totalTokenCount":9}}
        """)
        #expect(GeminiCodec.inbound(from: message) == [
            .audio(Data([1])),
            .audio(Data([2])),
            .inputTranscript("he is gasping"),
            .outputTranscript("stay with me"),
            .turnComplete,
            .usage(LiveUsage(totalTokens: 9)),
        ])
    }

    @Test func interruptedFollowsAnyAudioInTheSameMessage() throws {
        let message = try decodeServer("""
        {"serverContent":{"interrupted":true,"modelTurn":{"parts":[
          {"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AQ=="}}
        ]}}}
        """)
        #expect(GeminiCodec.inbound(from: message) == [.audio(Data([1])), .interrupted])
    }

    @Test func toolCall() throws {
        let message = try decodeServer("""
        {"toolCall":{"functionCalls":[
          {"id":"a","name":"say","args":{"phrase_id":"keep_going","state_version":3}}
        ]}}
        """)
        #expect(GeminiCodec.inbound(from: message) == [.functionCalls([
            RealtimeFunctionCall(id: "a", name: "say", args: ["phrase_id": "keep_going", "state_version": .number(3)]),
        ])])
    }

    @Test func toolCallCancellation() throws {
        let message = try decodeServer(#"{"toolCallCancellation":{"ids":["a","b"]}}"#)
        #expect(GeminiCodec.inbound(from: message) == [.functionCallsCancelled(["a", "b"])])
    }

    @Test func goAwayParsesItsDuration() throws {
        #expect(GeminiCodec.inbound(from: try decodeServer(#"{"goAway":{"timeLeft":"57s"}}"#)) == [.goAway(secondsLeft: 57)])
        #expect(GeminiCodec.inbound(from: try decodeServer(#"{"goAway":{"timeLeft":"1.5s"}}"#)) == [.goAway(secondsLeft: 1.5)])
    }

    @Test func goAwayStillCountsWhenItsDurationIsOdd() throws {
        #expect(GeminiCodec.inbound(from: try decodeServer(#"{"goAway":{"timeLeft":{"x":1}}}"#)) == [.goAway(secondsLeft: nil)])
        #expect(GeminiCodec.inbound(from: try decodeServer(#"{"goAway":{}}"#)) == [.goAway(secondsLeft: nil)])
        #expect(GeminiCodec.inbound(from: try decodeServer(#"{"goAway":"soon"}"#)) == [.goAway(secondsLeft: nil)])
    }

    @Test func sessionResumptionUpdate() throws {
        let good = try decodeServer(#"{"sessionResumptionUpdate":{"newHandle":"h1","resumable":true}}"#)
        #expect(GeminiCodec.inbound(from: good) == [.resumption(handle: "h1", resumable: true)])
        let notNow = try decodeServer(#"{"sessionResumptionUpdate":{"resumable":false}}"#)
        #expect(GeminiCodec.inbound(from: notNow) == [.resumption(handle: nil, resumable: false)])
    }

    @Test func usageMetadata() throws {
        let message = try decodeServer("""
        {"usageMetadata":{"promptTokenCount":1,"cachedContentTokenCount":2,"responseTokenCount":3,
          "toolUsePromptTokenCount":4,"thoughtsTokenCount":5,"totalTokenCount":6,
          "promptTokensDetails":[{"modality":"AUDIO","tokenCount":1}]}}
        """)
        #expect(message.usage == LiveUsage(
            promptTokens: 1, cachedTokens: 2, responseTokens: 3,
            toolUsePromptTokens: 4, thoughtsTokens: 5, totalTokens: 6
        ))
    }

    @Test func unknownFieldsAndTypesAreIgnored() throws {
        #expect(GeminiCodec.inbound(from: try decodeServer(#"{"somethingNew":{"a":[1,2,3]}}"#)).isEmpty)
        #expect(GeminiCodec.inbound(from: try decodeServer(#"{"voiceActivity":{"type":"ACTIVITY_START"}}"#)).isEmpty)
        #expect(GeminiCodec.inbound(from: try decodeServer(#"{"setupComplete":{"extra":1},"future":true}"#)) == [.ready])
    }

    @Test func aMalformedFieldLosesOnlyItself() throws {
        let message = try decodeServer(#"{"serverContent":{"turnComplete":"yes","modelTurn":7,"interrupted":true},"usageMetadata":"lots","goAway":{"timeLeft":"9s"}}"#)
        #expect(GeminiCodec.inbound(from: message) == [.interrupted, .goAway(secondsLeft: 9)])
    }

    @Test func invalidBase64AudioIsSkipped() throws {
        let message = try decodeServer("""
        {"serverContent":{"modelTurn":{"parts":[
          {"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"!!!not base64!!!"}},
          {"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AQ=="}}
        ]}}}
        """)
        #expect(GeminiCodec.inbound(from: message) == [.audio(Data([1]))])
    }

    @Test func nonAudioInlineDataIsNotPlayed() throws {
        let message = try decodeServer(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"image/png","data":"AQ=="}}]}}}"#)
        #expect(GeminiCodec.inbound(from: message).isEmpty)
    }

    @Test(arguments: [
        "", "not json", "null", "[]", "42", "\"text\"", "{", #"{"toolCall":"#, "\u{0}\u{1}",
    ])
    func framesThatAreNotObjectsDoNotDecode(_ frame: String) {
        #expect(GeminiCodec.decode(Data(frame.utf8)) == nil)
    }

    /// Runs on a task's small stack, where following deep JSON would crash the app.
    @Test(arguments: [33, 100, 400, 511, 513, 5_000, 200_000])
    func deepArgumentsAreRefusedAndNeverCrash(_ depth: Int) async {
        let prefix = #"{"toolCall":{"functionCalls":[{"id":"a","name":"say","args":"#
        for open in ["[", #"{"a":"#] {
            let close = open == "[" ? "]" : "}"
            let frame = prefix + String(repeating: open, count: depth) + "1" + String(repeating: close, count: depth) + "}]}}"
            let message = await Task.detached { GeminiCodec.decode(Data(frame.utf8)) }.value
            if let call = message?.functionCalls?.first {
                #expect(call.id == "a")
                #expect(call.args == nil)
            }
            let unbalanced = prefix + String(repeating: open, count: depth)
            _ = await Task.detached { GeminiCodec.decode(Data(unbalanced.utf8)) }.value
        }
    }

    @Test func ordinaryNestingStillDecodes() {
        let frame = #"{"toolCall":{"functionCalls":[{"id":"a","name":"say","args":{"a":{"b":{"c":[[1]]}}}}]}}"#
        let call = GeminiCodec.decode(Data(frame.utf8))?.functionCalls?.first
        #expect(call?.args == ["a": ["b": ["c": [[.number(1)]]]]])
    }

    @Test func oddFunctionCallShapesStillDecode() throws {
        let message = try decodeServer(#"{"toolCall":{"functionCalls":[{"id":7,"name":["x"],"args":"nope"},{}]}}"#)
        #expect(message.functionCalls == [
            RealtimeFunctionCall(id: nil, name: nil, args: .string("nope")),
            RealtimeFunctionCall(id: nil, name: nil, args: nil),
        ])
    }
}
