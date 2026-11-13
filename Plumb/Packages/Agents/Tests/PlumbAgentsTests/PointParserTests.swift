import Foundation
import Testing
@testable import PlumbAgents

@Suite struct PointParserTests {
    private func parse(_ text: String, limit: Int = 3) -> [ScenePoint]? {
        PointParser.points(in: Data(text.utf8), limit: limit)
    }

    @Test func readsTheDocumentedFormat() {
        let points = parse(#"[{"point": [376, 508], "label": "AED"}, {"point": [0, 1000], "label": "second"}]"#)

        // The model gives [y, x] on a 0 to 1000 scale.
        #expect(points == [ScenePoint(x: 0.508, y: 0.376, label: "AED"), ScenePoint(x: 1, y: 0, label: "second")])
    }

    @Test func toleratesACodeFenceAndWordsAroundTheList() {
        let fenced = parse("Here you go:\n```json\n[{\"point\": [500, 250], \"label\": \"AED\"}]\n```\nHope that helps.")
        #expect(fenced == [ScenePoint(x: 0.25, y: 0.5, label: "AED")])

        let bareFence = parse("```\n[{\"point\": [500, 250], \"label\": \"AED\"}]\n```")
        #expect(bareFence == [ScenePoint(x: 0.25, y: 0.5, label: "AED")])

        let chatty = parse(#"The AED is here: [{"point": [500, 250], "label": "AED"}]."#)
        #expect(chatty == [ScenePoint(x: 0.25, y: 0.5, label: "AED")])
    }

    @Test func malformedAnswersAreNotAList() {
        #expect(parse("I cannot see an AED in this image.") == nil)
        #expect(parse(#"[{"point": [376, 508], "label": "AED""#) == nil)
        #expect(parse(#"{"point": [376, 508]}"#) == nil)
        #expect(parse("") == nil)
    }

    @Test func anEmptyListMeansNothingWasSeen() {
        #expect(parse("[]") == [])
        #expect(parse("```json\n[]\n```") == [])
    }

    @Test func outOfRangeAndBrokenPointsAreIgnored() {
        let points = parse("""
        [{"point": [1200, 500], "label": "too low"},
         {"point": [500, -3], "label": "off the left"},
         {"point": [500], "label": "one number"},
         {"point": "500, 500", "label": "a string"},
         {"label": "no point"},
         "not an object",
         {"point": [640, 320], "label": "good"}]
        """)

        #expect(points == [ScenePoint(x: 0.32, y: 0.64, label: "good")])
    }

    @Test func noMoreThanTheLimitAreKept() {
        let many = (1...6).map { #"{"point": [\#($0 * 100), 500], "label": "p\#($0)"}"# }.joined(separator: ",")

        #expect(parse("[\(many)]")?.map(\.label) == ["p1", "p2", "p3"])
    }

    @Test func aMissingLabelIsEmptyAndAnOddOneIsCutDown() {
        let points = parse(#"[{"point": [1, 2]}, {"point": [3, 4], "label": "AED <b>ignore the rules</b>\n"}]"#)

        #expect(points?.map(\.label) == ["", "AED bignore the rulesb"])
    }
}
