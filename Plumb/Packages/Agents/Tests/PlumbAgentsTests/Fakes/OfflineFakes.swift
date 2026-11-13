import Foundation
import PlumbContracts
@testable import PlumbAgents

/// A transcriber that hears whatever the test says was said.
@MainActor
final class FakeTranscriber: SpeechTranscribing {
    var readiness = TranscriberReadiness.ready(.speechAnalyzer)
    var transcript: String?
    var beginFailure: (any Error)?
    private(set) var prepared = 0
    private(set) var begun = 0
    private(set) var finished = 0

    init(transcript: String?) {
        self.transcript = transcript
    }

    func prepare() async -> TranscriberReadiness {
        prepared += 1
        return readiness
    }

    func begin() throws {
        if let beginFailure { throw beginFailure }
        begun += 1
    }

    func finish() async -> String? {
        finished += 1
        return transcript
    }
}

/// A classifier that always reads the same intent, and remembers what it was asked.
final class FakeClassifier: IntentClassifying, Sendable {
    let reading: IntentReading
    private let asked = Locked<[String]>([])
    private let prepares = Locked(0)
    /// Called on every question, so a test can see what happened in what order.
    private let onClassify: @Sendable () -> Void

    init(_ reading: IntentReading, onClassify: @escaping @Sendable () -> Void = {}) {
        self.reading = reading
        self.onClassify = onClassify
    }

    var questions: [String] { asked.current }
    var prepared: Int { prepares.current }

    func prepare() {
        prepares.with { $0 += 1 }
    }

    func classify(_ question: String) async -> IntentReading {
        asked.with { $0.append(question) }
        onClassify()
        return reading
    }
}

/// A digest with a few fields changed from the ordinary one.
func changedDigest(_ change: (inout WorldDigest) -> Void) -> WorldDigest {
    var digest = freshDigest()
    change(&digest)
    return digest
}
