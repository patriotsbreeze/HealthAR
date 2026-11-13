import Foundation
import PlumbContracts
import Testing
@testable import PlumbAgents

@MainActor
@Suite struct OfflineAskTests {
    /// What happened, in order, across the classifier and the digest reader.
    private let steps = Locked<[String]>([])

    private func makeAsk(heard: String?, classifier: (any IntentClassifying)? = nil,
                     digest: WorldDigest = freshDigest()) -> (OfflineAsk, FakeTranscriber) {
        let transcriber = FakeTranscriber(transcript: heard)
        let steps = self.steps
        let ask = OfflineAsk(transcriber: transcriber, classifier: classifier ?? KeywordIntentClassifier(),
                             read: {
                                 steps.with { $0.append("read") }
                                 return digest
                             })
        return (ask, transcriber)
    }

    @Test func aQuestionIsHeardReadAndAnsweredWithAFixedSentence() async throws {
        let (ask, transcriber) = makeAsk(heard: "  How fast am I going? ")

        try ask.begin()
        #expect(ask.isListening)
        let result = await ask.end()

        #expect(result == OfflineAskResult(heard: "How fast am I going?", intent: .rate,
                                           answer: "112 per minute, within the target of 100 to 120.",
                                           classifiedBy: .keywords, fallbackReason: nil))
        #expect(!ask.isListening)
        #expect(transcriber.begun == 1)
        #expect(transcriber.finished == 1)
    }

    @Test func theModelOnlyPicksTheIntentAndTheWordsStayFixed() async throws {
        let model = FakeClassifier(IntentReading(intent: .depth, classifiedBy: .model))
        let (ask, _) = makeAsk(heard: "am I doing enough", classifier: model)

        try ask.begin()
        let result = await ask.end()

        #expect(result.intent == .depth)
        #expect(result.classifiedBy == .model)
        #expect(result.answer == "5.5 centimetres deep, within the target of 5 to 6.")
        #expect(model.questions == ["am I doing enough"])
    }

    @Test func theFallbackReasonIsCarriedThrough() async throws {
        let fallback = FakeClassifier(IntentReading(intent: .count, classifiedBy: .keywords,
                                                    fallbackReason: "Apple Intelligence is turned off."))
        let (ask, _) = makeAsk(heard: "how many", classifier: fallback)

        try ask.begin()
        let result = await ask.end()

        #expect(result.fallbackReason == "Apple Intelligence is turned off.")
        #expect(result.answer == "87 compressions so far.")
    }

    @Test(arguments: [nil, "", "   \n"] as [String?])
    func nothingHeardGivesTheFixedPromptAndReadsNothing(_ transcript: String?) async throws {
        let model = FakeClassifier(IntentReading(intent: .overall, classifiedBy: .model))
        let (ask, _) = makeAsk(heard: transcript, classifier: model)

        try ask.begin()
        let result = await ask.end()

        #expect(result == OfflineAskResult(heard: nil, intent: .unknown, answer: OfflineAnswerer.nothingHeard,
                                           classifiedBy: nil))
        #expect(model.questions.isEmpty)
        #expect(steps.current.isEmpty)
    }

    @Test func aQuestionAboutAPersonIsNeverAnsweredFromTheNumbers() async throws {
        let model = FakeClassifier(IntentReading(intent: .overall, classifiedBy: .model))
        let (ask, _) = makeAsk(heard: "Is he breathing?", classifier: model)

        try ask.begin()
        let result = await ask.end()

        #expect(result.intent == .unknown)
        #expect(result.answer == OfflineAnswerer.topics)
        #expect(result.classifiedBy == .keywords)
        #expect(model.questions.isEmpty)
    }

    /// No condition word at all, and a model that reads it as asking how it is going: the person is
    /// named, so the numbers are still not read back, and the model is never asked.
    @Test(arguments: ["How is he doing?", "Is she doing okay?", "Will the patient make it?"])
    func aQuestionNamingThePersonIsNeverAnsweredFromTheNumbers(_ question: String) async throws {
        let model = FakeClassifier(IntentReading(intent: .overall, classifiedBy: .model))
        let (ask, _) = makeAsk(heard: question, classifier: model)

        try ask.begin()
        let result = await ask.end()

        #expect(result.intent == .unknown)
        #expect(result.answer == OfflineAnswerer.topics)
        #expect(model.questions.isEmpty)
    }

    @Test func staleNumbersMeanItSaysItCannotSee() async throws {
        let (ask, _) = makeAsk(heard: "how deep am I", digest: changedDigest { $0.stale = true })

        try ask.begin()
        let result = await ask.end()

        #expect(result.intent == .depth)
        #expect(result.answer == "I can't see the hands right now.")
    }

    @Test func theDigestIsReadOnlyAfterTheQuestionIsUnderstood() async throws {
        let steps = self.steps
        let model = FakeClassifier(IntentReading(intent: .rate, classifiedBy: .model)) {
            steps.with { $0.append("classify") }
        }
        let (ask, _) = makeAsk(heard: "rate?", classifier: model)

        try ask.begin()
        #expect(steps.current.isEmpty)
        _ = await ask.end()

        #expect(steps.current == ["classify", "read"])
    }

    @Test func aFailureToStartListeningIsPassedOnAndNothingIsListening() {
        let (ask, transcriber) = makeAsk(heard: "rate?")
        transcriber.beginFailure = OnDeviceTranscriber.Failure.noInput

        #expect(throws: OnDeviceTranscriber.Failure.noInput) { try ask.begin() }
        #expect(!ask.isListening)
    }

    @Test func pressingAgainWhileListeningDoesNotStartASecondListen() throws {
        let (ask, transcriber) = makeAsk(heard: "rate?")

        try ask.begin()
        try ask.begin()

        #expect(transcriber.begun == 1)
    }

    @Test func prepareGetsTheTranscriberAndTheModelReady() async {
        let model = FakeClassifier(IntentReading(intent: .rate, classifiedBy: .model))
        let (ask, transcriber) = makeAsk(heard: nil, classifier: model)
        transcriber.readiness = .unavailable(reason: "Speech recognition is not allowed.")

        let readiness = await ask.prepare()

        #expect(readiness == .unavailable(reason: "Speech recognition is not allowed."))
        #expect(transcriber.prepared == 1)
        #expect(model.prepared == 1)
    }

    @Test func theLogSaysWhoDecidedEachPart() {
        let byModel = OfflineAskResult(heard: "how fast", intent: .rate, answer: "112 per minute, within the target of 100 to 120.",
                                       classifiedBy: .model)
        let byKeywords = OfflineAskResult(heard: "how fast", intent: .rate, answer: "112 per minute, within the target of 100 to 120.",
                                          classifiedBy: .keywords, fallbackReason: "The on-device model took longer than 1.5 seconds.")
        let nothing = OfflineAskResult(heard: nil, intent: .unknown, answer: OfflineAnswerer.nothingHeard, classifiedBy: nil)

        #expect(byModel.logLines.map(\.source) == [.said, .model, .rule])
        #expect(byModel.logLines.map(\.body) == [
            .note("Asked: how fast"),
            .note("Read the question as rate, on this phone."),
            .note("Answered: 112 per minute, within the target of 100 to 120."),
        ])
        #expect(byKeywords.logLines.map(\.source) == [.said, .rule, .rule])
        #expect(byKeywords.logLines[1].body
            == .note("Read the question as rate from its words. The on-device model took longer than 1.5 seconds."))
        #expect(nothing.logLines.map(\.source) == [.rule])
    }
}
