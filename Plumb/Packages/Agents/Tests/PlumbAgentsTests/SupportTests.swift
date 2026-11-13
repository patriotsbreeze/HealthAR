import Foundation
import Testing
@testable import PlumbAgents

@Suite struct JSONValueTests {
    @Test func aDocumentSurvivesARoundTrip() throws {
        let text = #"{"a":[1,2.5,"three",true,null,{"deep":[]}],"b":{"c":-4}}"#

        let value = try JSONValue(parsing: Data(text.utf8))

        #expect(value["a"]?.array?.count == 6)
        #expect(value["a"]?.array?[1] == .number(2.5))
        #expect(value["a"]?.array?[4] == .null)
        #expect(value["b"]?["c"]?.number == -4)
        #expect(String(decoding: try value.encoded(), as: UTF8.self) == text)
    }

    @Test func keysAreWrittenInAFixedOrderAndWholeNumbersHaveNoDecimalPoint() throws {
        let value: JSONValue = ["zebra": 1, "apple": [true, "b/c"], "mango": [:]]

        #expect(String(decoding: try value.encoded(), as: UTF8.self) == #"{"apple":[true,"b/c"],"mango":{},"zebra":1}"#)
    }

    @Test func readingTheWrongKindGivesNil() {
        let value: JSONValue = ["name": "x"]

        #expect(value["name"]?.number == nil)
        #expect(value["missing"] == nil)
        #expect(value.string == nil)
        #expect(JSONValue.string("x")["name"] == nil)
    }

    @Test func schemaBuildersProducePlainJSONSchema() {
        let schema = JSONSchema.object([
            "ids": JSONSchema.array(of: JSONSchema.integer(oneOf: [3, 5]), minItems: 1, maxItems: 2),
            "note": JSONSchema.string(description: "A note."),
        ], required: ["ids"])

        #expect(schema == [
            "type": "object",
            "properties": [
                "ids": ["type": "array", "items": ["type": "integer", "enum": [3, 5]], "minItems": 1, "maxItems": 2],
                "note": ["type": "string", "description": "A note."],
            ],
            "required": ["ids"],
        ])
    }
}

@Suite struct ScrubberTests {
    @Test func theSecretIsRemovedBeforeTheTextIsCut() {
        let text = "0123456789 key=\(secretKey) and more"

        #expect(Scrubber.clean(text, secret: secretKey, limit: 20) == "0123456789 key=[key]…")
        #expect(!Scrubber.clean(text, secret: secretKey, limit: 18).contains("AIza"))
    }

    @Test func textIsFlattenedToOneLine() {
        #expect(Scrubber.flatten("one\n\ttwo  \r\n three\u{0}", limit: 50) == "one two three")
    }

    @Test func anEmptySecretChangesNothing() {
        #expect(Scrubber.clean("plain", secret: "", limit: 50) == "plain")
    }

    @Test func aLabelKeepsOnlyPlainCharacters() {
        #expect(Scrubber.label("get_cpr-quality v2.1") == "get_cpr-quality v2.1")
        #expect(Scrubber.label("  <b>\"AED\"</b>\n") == "bAEDb")
        #expect(Scrubber.label(String(repeating: "a", count: 90)).count == 40)
    }
}

@Suite struct FencedJSONTests {
    @Test func bareTextIsOnlyTrimmed() {
        #expect(FencedJSON.unwrap("  [1, 2]\n") == "[1, 2]")
    }

    @Test func aFenceWithOrWithoutALanguageTagIsRemoved() {
        #expect(FencedJSON.unwrap("```json\n{\"a\": 1}\n```") == "{\"a\": 1}")
        #expect(FencedJSON.unwrap("Sure:\n```\n[]\n```\nDone.") == "[]")
    }

    @Test func anUnclosedFenceStillGivesItsContent() {
        #expect(FencedJSON.unwrap("```json\n[1]") == "[1]")
    }
}

@Suite struct ConfigTests {
    @Test func defaultsAreTheDocumentedOnes() {
        let config = AgentsConfig()

        #expect(config.textModel == "gemini-3.8-flash")
        #expect(config.pointingModel == "gemini-robotics-er-2-preview")
        #expect(config.pointingFallbackModel == "gemini-3.8-flash")
        #expect(config.liveModel == "gemini-3.8-live")
        #expect(config.restDialect == .interactions)
        #expect(config.maxConcurrentToolCalls == 2)
        #expect(config.sceneLabel == "AED")
        #expect(config.sceneMaxPoints == 3)
        #expect(config.sceneMinDistanceM == 0.3 && config.sceneMaxDistanceM == 5)
        #expect(config.sceneMinSideM == 0.15 && config.sceneMaxSideM == 0.6)
        #expect(config.sceneMinReliefM == 0.04)
        #expect(config.scribeMaxSentences == 3 && config.scribeMaxWords == 30)
    }
}
