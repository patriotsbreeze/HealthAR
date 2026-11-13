import Foundation
import Testing
@testable import PlumbAgents

/// A stand-in model: says whether it is there, counts warm-ups and questions, and answers as told.
private final class ScriptedModel: Sendable {
    let reason: String?
    let prepares = Locked(0)
    let asks = Locked(0)
    let answer: @Sendable (String) async throws -> AskIntent

    init(unavailable reason: String? = nil, answer: @escaping @Sendable (String) async throws -> AskIntent) {
        self.reason = reason
        self.answer = answer
    }

    var model: IntentModel {
        IntentModel(unavailableReason: { self.reason },
                    prepare: { self.prepares.with { $0 += 1 } },
                    ask: { question in
                        self.asks.with { $0 += 1 }
                        return try await self.answer(question)
                    })
    }
}

private struct ModelBroke: Error {}

@Suite struct OnDeviceIntentClassifierTests {
    @Test func theModelsIntentIsUsedWhenItAnswersInTime() async {
        let scripted = ScriptedModel { _ in .depth }
        let classifier = OnDeviceIntentClassifier(timeLimit: .seconds(1), model: scripted.model)

        let reading = await classifier.classify("am I pushing enough")

        #expect(reading == IntentReading(intent: .depth, classifiedBy: .model, fallbackReason: nil))
    }

    @Test func aMissingModelFallsBackToKeywordsAndSaysWhy() async {
        let scripted = ScriptedModel(unavailable: "Apple Intelligence is turned off.") { _ in .depth }
        let classifier = OnDeviceIntentClassifier(timeLimit: .seconds(1), model: scripted.model)

        let reading = await classifier.classify("how fast am I going")
        classifier.prepare()

        #expect(reading == IntentReading(intent: .rate, classifiedBy: .keywords,
                                         fallbackReason: "Apple Intelligence is turned off."))
        #expect(scripted.asks.current == 0)
        #expect(scripted.prepares.current == 0)
    }

    @Test func aFailingModelFallsBackToKeywords() async {
        let scripted = ScriptedModel { _ in throw ModelBroke() }
        let classifier = OnDeviceIntentClassifier(timeLimit: .seconds(1), model: scripted.model)

        let reading = await classifier.classify("how many have I done")

        #expect(reading == IntentReading(intent: .count, classifiedBy: .keywords,
                                         fallbackReason: "The on-device model could not read the question."))
    }

    @Test func aSlowModelIsAbandonedAtTheTimeLimit() async {
        let scripted = ScriptedModel { _ in
            try await Task.sleep(for: .seconds(30))
            return .depth
        }
        let classifier = OnDeviceIntentClassifier(timeLimit: .milliseconds(200), model: scripted.model)
        let clock = ContinuousClock()
        let started = clock.now

        let reading = await classifier.classify("did I stop")

        #expect(clock.now - started < .seconds(2))
        #expect(reading == IntentReading(intent: .pauses, classifiedBy: .keywords,
                                         fallbackReason: "The on-device model took longer than 0.2 seconds."))
    }

    @Test func aModelThatIgnoresCancellationStillCannotHoldUpTheAnswer() async {
        let gate = Gate()
        let scripted = ScriptedModel { _ in
            await gate.wait()
            return .depth
        }
        let classifier = OnDeviceIntentClassifier(timeLimit: .milliseconds(150), model: scripted.model)
        let clock = ContinuousClock()
        let started = clock.now

        let reading = await classifier.classify("how am I doing")
        gate.open()

        #expect(clock.now - started < .seconds(2))
        #expect(reading.intent == .overall)
        #expect(reading.classifiedBy == .keywords)
    }

    @Test func prepareWarmsTheModelOnlyWhenItIsThere() {
        let scripted = ScriptedModel { _ in .rate }

        OnDeviceIntentClassifier(timeLimit: .seconds(1), model: scripted.model).prepare()

        #expect(scripted.prepares.current == 1)
    }

    @Test func aBuildWithoutTheModelSaysSo() async {
        let classifier = OnDeviceIntentClassifier(timeLimit: .seconds(1), model: .missing("Not here."))

        let reading = await classifier.classify("what's my rate")

        #expect(reading == IntentReading(intent: .rate, classifiedBy: .keywords, fallbackReason: "Not here."))
    }

    @Test func aCancelledCallerStopsWaitingForTheModel() async {
        let scripted = ScriptedModel { _ in
            try await Task.sleep(for: .seconds(30))
            return .depth
        }
        let classifier = OnDeviceIntentClassifier(timeLimit: .seconds(20), model: scripted.model)
        let clock = ContinuousClock()
        let started = clock.now

        let asking = Task { await classifier.classify("how deep") }
        try? await Task.sleep(for: .milliseconds(50))
        asking.cancel()
        let reading = await asking.value

        #expect(clock.now - started < .seconds(5))
        #expect(reading.classifiedBy == .keywords)
        #expect(reading.intent == .depth)
    }
}

/// Runs the real on-device model. Off by default, because it needs a Mac or phone with Apple
/// Intelligence switched on; run with PLUMB_ON_DEVICE_MODEL=1 to try it.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PLUMB_ON_DEVICE_MODEL"] == "1"))
struct OnDeviceModelLiveTests {
    @Test(arguments: [
        ("How fast am I going?", AskIntent.rate),
        ("Am I pushing deep enough?", .depth),
        ("How long was I stopped for?", .pauses),
        ("How many compressions have I done?", .count),
        ("How am I doing?", .overall),
        ("What's the capital of France?", .unknown),
    ])
    func theRealModelPicksTheIntent(question: String, expected: AskIntent) async {
        let classifier = OnDeviceIntentClassifier(timeLimit: .seconds(10))
        classifier.prepare()

        let reading = await classifier.classify(question)

        #expect(reading.classifiedBy == .model, "\(reading.fallbackReason ?? "")")
        #expect(reading.intent == expected)
    }
}
