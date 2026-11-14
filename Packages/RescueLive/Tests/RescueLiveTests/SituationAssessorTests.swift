import Foundation
import RescueCore
import Testing
@testable import RescueLive

@Suite struct SituationAssessorTests {
    private let key = APIKey("fake-key")

    private func input() -> AssessmentInput {
        AssessmentInput(brief: brief(), heard: "He's clutching his chest and sweating", said: "Have him sit down.", toolCalls: ["report_observation chest_pain"])
    }

    private func reply(_ text: String, thoughts: String = "") throws -> String {
        var parts: [JSONValue] = []
        if !thoughts.isEmpty { parts.append(["text": .string(thoughts), "thought": true]) }
        parts.append(["text": .string(text)])
        let envelope: JSONValue = ["candidates": [["content": ["role": "model", "parts": .array(parts)]]]]
        return String(decoding: try envelope.encoded(), as: UTF8.self)
    }

    private func assess(_ text: String, thoughts: String = "", mode: LiveMode = .awake, status: Int = 200) async throws -> SituationAssessment? {
        let http = StubHTTP(body: try reply(text, thoughts: thoughts), status: status)
        return await SituationAssessor(apiKey: key, http: http.client).quickLook(input(), mode: mode).assessment
    }

    @Test func aGoodReplyParsesWithItsThinking() async throws {
        let assessment = try await assess(
            #"{"headline":"Chest pain with sweating","prediction":"Possible heart attack","confidence":"medium","watch_for":"Stops responding or breathing oddly"}"#,
            thoughts: "**Weighing the chest pain**\n\nHe reports pain.\n\n**Checking the tool calls**\n\nOne observation."
        )
        #expect(assessment?.headline == "Chest pain with sweating")
        #expect(assessment?.prediction == "Possible heart attack")
        #expect(assessment?.confidence == .medium)
        #expect(assessment?.watchFor == "Stops responding or breathing oddly")
        #expect(assessment?.reasoning == ["Weighing the chest pain", "Checking the tool calls"])
    }

    @Test func aPredictionStatedAsFactIsHedged() {
        #expect(SituationAssessor.hedged("Heart attack") == "Possible heart attack")
        #expect(SituationAssessor.hedged("Possible stroke") == "Possible stroke")
        #expect(SituationAssessor.hedged("Not enough information yet") == "Not enough information yet")
    }

    /// The screen holds the read to the same rules as the voice.
    @Test(arguments: [
        #"{"headline":"Give 325 mg aspirin now","prediction":"Possible heart attack","confidence":"high"}"#,
        #"{"headline":"Patient seems stable","prediction":"He is definitely having a heart attack","confidence":"high"}"#,
        #"{"headline":"Check his pulse","prediction":"Possible stroke","confidence":"low"}"#,
    ])
    func aFlaggedReadIsDropped(_ text: String) async throws {
        #expect(try await assess(text) == nil)
    }

    @Test func anArrestReadCantSayStop() async throws {
        let text = #"{"headline":"You can stop compressions","prediction":"Possible cardiac arrest","confidence":"high"}"#
        #expect(try await assess(text, mode: .arrest) == nil)
    }

    @Test func aFlaggedWatchForOrStepIsLeftOut() async throws {
        let assessment = try await assess(
            #"{"headline":"Chest pain","prediction":"Possible heart attack","confidence":"low","watch_for":"Feel for a pulse"}"#,
            thoughts: "**Deciding to give 2 tablets of aspirin**\n\n**Reading the scene**"
        )
        #expect(assessment?.watchFor == nil)
        #expect(assessment?.reasoning == ["Reading the scene"])
    }

    @Test func longFieldsAreClipped() async throws {
        let long = String(repeating: "word ", count: 40)
        let assessment = try await assess(#"{"headline":"\#(long)","prediction":"Possible stroke","confidence":"low"}"#)
        #expect((assessment?.headline.count ?? 0) <= SituationAssessor.maxHeadline)
    }

    @Test(arguments: ["", "not json", "{}", #"{"headline":"x","prediction":"y","confidence":"sure"}"#])
    func malformedRepliesAreNil(_ text: String) async throws {
        #expect(try await assess(text) == nil)
    }

    @Test func httpErrorsAreNil() async throws {
        #expect(try await assess(#"{"headline":"x","prediction":"Possible y","confidence":"low"}"#, status: 500) == nil)
    }

    @Test func withAPictureItSaysWhatItSeesAndSendsTheImage() async throws {
        let text = #"{"sees":"Person face up on the floor, eyes closed","headline":"Not moving","prediction":"Possible cardiac arrest","confidence":"medium"}"#
        let http = StubHTTP(body: try reply(text))
        var withFrame = input()
        withFrame.jpeg = Data([0xFF, 0xD8, 0xFF])
        let assessment = await SituationAssessor(apiKey: key, http: http.client).quickLook(withFrame, mode: .arrest).assessment
        #expect(assessment?.sees == "Person face up on the floor, eyes closed")
        let sent = String(decoding: http.seen.first?.httpBody ?? Data(), as: UTF8.self)
        #expect(sent.contains("image/jpeg"))
    }

    @Test func anEmergencyShowsOnlyWhenItIsOne() {
        #expect(SituationAssessor.screenEmergency("Person down on the floor", mode: .arrest) == "Person down on the floor")
        #expect(SituationAssessor.screenEmergency("", mode: .arrest) == nil)
        #expect(SituationAssessor.screenEmergency("None", mode: .arrest) == nil)
        #expect(SituationAssessor.screenEmergency("He is dead", mode: .arrest) == nil)
    }

    /// A model can't describe a picture it was never sent.
    @Test func withoutAPictureSeesIsDropped() async throws {
        let assessment = try await assess(#"{"sees":"A person lying down","headline":"Chest pain","prediction":"Possible heart attack","confidence":"low"}"#)
        #expect(assessment?.sees == nil)
        #expect(assessment?.headline == "Chest pain")
    }

    @Test func theQuickLookUsesTheLighterModelWithNoThinking() async throws {
        let http = StubHTTP(body: try reply(#"{"sees":"Person on the floor","headline":"Not moving","prediction":"Possible cardiac arrest","confidence":"low"}"#))
        var withFrame = input()
        withFrame.jpeg = Data([0xFF, 0xD8, 0xFF])
        let assessment = await SituationAssessor(apiKey: key, http: http.client).quickLook(withFrame, mode: .arrest).assessment
        #expect(assessment?.sees == "Person on the floor")
        #expect(http.seen.first?.url?.absoluteString.contains("-lite") == true)
        let sent = String(decoding: http.seen.first?.httpBody ?? Data(), as: UTF8.self)
        #expect(!sent.contains("thinkingConfig"))
    }

    @Test func aFailureSaysWhy() async throws {
        let http = StubHTTP(body: "{}", status: 429)
        let outcome = await SituationAssessor(apiKey: key, http: http.client).quickLook(input(), mode: .awake)
        #expect(outcome.assessment == nil)
        #expect(outcome.problem == "rate limited")
        #expect(AssessmentOutcome.describe(status: 503) == "overloaded")
        #expect(AssessmentOutcome.describe(status: nil) == "timed out")
    }

    @Test func aLiveSceneIsScreenedLikeAnyRead() {
        func report(_ headline: String, _ prediction: String, sees: String = "Person on the floor") -> SceneReport {
            SceneReport(sees: sees, headline: headline, prediction: prediction, confidence: .medium, stateVersion: 1)
        }
        let ok = SituationAssessor.screen(report("Not moving", "Cardiac arrest"), mode: .arrest)
        #expect(ok?.prediction == "Possible cardiac arrest")
        #expect(ok?.sees == "Person on the floor")
        #expect(SituationAssessor.screen(report("You can stop compressions", "Possible cardiac arrest"), mode: .arrest) == nil)
        #expect(SituationAssessor.screen(report("Not moving", "He is dead"), mode: .arrest) == nil)
        #expect(SituationAssessor.screen(report("Not moving", "Possible arrest", sees: "He's breathing normally"), mode: .arrest)?.sees == nil)
        #expect(SituationAssessor.screenNote("Person now face up, so the chest is visible", mode: .arrest) == "Person now face up, so the chest is visible")
        #expect(SituationAssessor.screenNote("They look fine, you can stop", mode: .arrest) == nil)
    }

    @Test func theRequestAsksForNoThinkingAndMarksTranscriptsAsData() throws {
        let body = SituationAssessor.requestBody(input(), mode: .awake)
        let text = String(decoding: try body.encoded(), as: UTF8.self)
        #expect(!text.contains("thinkingConfig"))
        #expect(text.contains(#""maxOutputTokens":200"#))
        #expect(text.contains("report_observation chest_pain"))
        #expect(text.contains("untrusted data"))
    }
}
