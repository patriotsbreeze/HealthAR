import Foundation
import PlumbContracts

/// "Hold to ask" with no network and no key: speech to text on the phone, the question sorted into
/// one of a few intents, and a fixed sentence filled in from the latest measurements.
///
/// Nothing a model produces is ever said. The model, when there is one, only picks an intent from a
/// closed set; the words come from `OfflineAnswerer`. A question about a person's condition is never
/// answered from the measurements, whichever classifier would have read it. The digest is read after
/// the question is understood, so the answer uses the newest numbers.
@MainActor
public final class OfflineAsk {
    /// True between `begin()` and `end()`.
    public private(set) var isListening = false

    private let transcriber: any SpeechTranscribing
    private let classifier: any IntentClassifying
    private let targets: Targets
    private let read: @Sendable () async -> WorldDigest

    /// The on-device recognizer and the on-device model, with the keyword rules as the fallback.
    ///
    /// - Parameter read: returns the app's current digest of the measurements, as for `GetCPRQuality`.
    public convenience init(targets: Targets = .adult, read: @escaping @Sendable () async -> WorldDigest) {
        self.init(transcriber: OnDeviceTranscriber(), classifier: OnDeviceIntentClassifier(), targets: targets, read: read)
    }

    /// - Parameters:
    ///   - transcriber: turns the held press into text.
    ///   - classifier: picks the intent of the text.
    ///   - read: returns the app's current digest of the measurements.
    public init(transcriber: any SpeechTranscribing, classifier: any IntentClassifying, targets: Targets = .adult,
                read: @escaping @Sendable () async -> WorldDigest) {
        self.transcriber = transcriber
        self.classifier = classifier
        self.targets = targets
        self.read = read
    }

    /// Gets speech recognition and the model ready. Call at launch while online, so the speech model
    /// can be fetched once; questions then work offline. Safe to call again.
    @discardableResult
    public func prepare() async -> TranscriberReadiness {
        classifier.prepare()
        return await transcriber.prepare()
    }

    /// The button went down: starts listening. Does nothing when already listening.
    public func begin() throws {
        guard !isListening else { return }
        try transcriber.begin()
        isListening = true
    }

    /// The button came up: stops listening and works out the answer to say.
    public func end() async -> OfflineAskResult {
        isListening = false
        guard let heard = await transcriber.finish().flatMap(Self.cleaned) else {
            return OfflineAskResult(heard: nil, intent: .unknown, answer: OfflineAnswerer.nothingHeard, classifiedBy: nil)
        }
        let reading: IntentReading
        if KeywordIntentClassifier.asksAboutCondition(heard) {
            reading = IntentReading(intent: .unknown, classifiedBy: .keywords,
                                    fallbackReason: "Questions about a person's condition are not answered.")
        } else {
            reading = await classifier.classify(heard)
        }
        let digest = await read()
        return OfflineAskResult(heard: heard, intent: reading.intent,
                                answer: OfflineAnswerer.answer(intent: reading.intent, digest: digest, targets: targets),
                                classifiedBy: reading.classifiedBy, fallbackReason: reading.fallbackReason)
    }

    /// The transcript trimmed, or nil when nothing but space is left.
    private static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
