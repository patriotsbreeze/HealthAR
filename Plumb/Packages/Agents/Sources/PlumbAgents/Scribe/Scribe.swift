import Foundation
import PlumbContracts

/// Asks a model for up to three plain sentences about a finished session, and lets a fixed checker
/// decide which of them a person will ever see.
///
/// The scribe never has the last word: a sentence is kept only when the checker accepts exactly
/// that sentence. The handoff is complete without it, so every failure here is quiet.
public struct Scribe: Sendable {
    private let client: any JSONGenerating
    private let config: AgentsConfig

    /// - Parameter client: where the requests go. `GeminiClient` in the app, a fake in tests.
    public init(client: any JSONGenerating, config: AgentsConfig = AgentsConfig()) {
        self.client = client
        self.config = config
    }

    /// Writes the sentences for one handoff.
    ///
    /// One request is made. If the checker refuses any sentence, one more request asks for
    /// replacements for those sentences only, and they are checked in turn. Then it stops.
    ///
    /// - Parameters:
    ///   - log: the session log. Only measurements and fixed events are shown to the model.
    ///   - stats: the measured summary the handoff already shows.
    ///   - headline: the handoff's headline, so the model does not repeat it.
    ///   - verify: the fixed checker. It is given sentences and returns one verdict for each.
    public func write(log: [LogEntry], stats: HandoffStats, headline: String,
                      verify: @Sendable ([ScribeSentence]) -> [ScribeVerdict]) async -> ScribeResult {
        let clock = ContinuousClock()
        let started = clock.now
        var result = await compose(log: log, stats: stats, headline: headline, verify: verify)
        result.seconds = (clock.now - started).inSeconds
        return result
    }

    // MARK: - Private

    private struct Problem: Error {
        var sentence: String
    }

    private func compose(log: [LogEntry], stats: HandoffStats, headline: String,
                         verify: @Sendable ([ScribeSentence]) -> [ScribeVerdict]) async -> ScribeResult {
        var result = ScribeResult()
        let digest = ScribeLogDigest(log: log, config: config)
        guard !digest.ids.isEmpty else {
            result.failure = "The log holds nothing the scribe could write about."
            return result
        }
        let offered = Set(digest.ids)
        let brief = ScribePrompt.brief(headline: headline, stats: stats, digest: digest,
                                       stride: config.scribeCompressionStride)

        result.requests = 1
        let drafts: [ScribeSentence]
        switch await ask(brief, ids: digest.ids, limit: config.scribeMaxSentences) {
        case .success(let sentences):
            drafts = sentences
        case .failure(let problem):
            result.failure = problem.sentence
            return result
        }
        let first = check(drafts, offered: offered, verify: verify)
        result.verdicts = first
        var slots: [ScribeSentence?] = first.map { $0.accepted ? $0.sentence : nil }
        let refusedAt = first.indices.filter { !first[$0].accepted }

        if !refusedAt.isEmpty {
            result.requests = 2
            let again = ScribePrompt.replacementBrief(brief, kept: slots.compactMap { $0 },
                                                      refused: refusedAt.map { first[$0] })
            switch await ask(again, ids: digest.ids, limit: refusedAt.count) {
            case .success(let replacements):
                let second = check(replacements, offered: offered, verify: verify)
                result.verdicts += second
                // The nth replacement stands in for the nth refused sentence, keeping the reading order.
                for (slot, verdict) in zip(refusedAt, second) where verdict.accepted {
                    slots[slot] = verdict.sentence
                }
            case .failure(let problem):
                result.failure = problem.sentence
            }
        }

        var said = Set<String>()
        result.accepted = slots.compactMap { $0 }.filter { said.insert($0.text).inserted }
        return result
    }

    /// One request to the model, parsed into at most `limit` sentences.
    private func ask(_ brief: String, ids: [Int], limit: Int) async -> Result<[ScribeSentence], Problem> {
        let schema = ScribePrompt.schema(ids: ids, maxSentences: limit, maxWords: config.scribeMaxWords)
        let answer: Data
        do {
            answer = try await client.generateJSON(model: config.textModel, system: ScribePrompt.system(config: config),
                                                   parts: [.text(brief)], schema: schema,
                                                   thinking: config.scribeThinkingLevel, timeout: config.scribeTimeout)
        } catch let error as GeminiError {
            return .failure(Problem(sentence: "The scribe could not be reached. \(error.description)"))
        } catch {
            // An unknown error could say anything, so it is not repeated.
            return .failure(Problem(sentence: "The scribe could not be reached."))
        }
        let text = FencedJSON.unwrap(String(decoding: answer, as: UTF8.self))
        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(text.utf8)) else {
            return .failure(Problem(sentence: "The scribe's answer was not in the agreed form."))
        }
        let sentences = reply.sentences.prefix(limit).map {
            ScribeSentence(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), cites: $0.cites)
        }
        return .success(Array(sentences))
    }

    private struct Reply: Decodable {
        var sentences: [Line]
        struct Line: Decodable {
            var text: String
            var cites: [Int]
        }
    }

    /// One verdict per sentence, in the same order. Fails closed: a sentence the checker returns no
    /// verdict for is refused.
    private func check(_ sentences: [ScribeSentence], offered: Set<Int>,
                       verify: @Sendable ([ScribeSentence]) -> [ScribeVerdict]) -> [ScribeVerdict] {
        let formProblems = sentences.map {
            ScribeGate.refusal(for: $0, offered: offered, maxWords: config.scribeMaxWords)
        }
        let wellFormed = zip(sentences, formProblems).filter { $0.1 == nil }.map(\.0)
        var returned = wellFormed.isEmpty ? [] : verify(wellFormed)
        return zip(sentences, formProblems).map { sentence, problem in
            if let problem {
                return ScribeVerdict(sentence: sentence, accepted: false, reason: problem)
            }
            if let index = returned.firstIndex(where: { $0.sentence == sentence }) {
                return returned.remove(at: index)
            }
            return ScribeVerdict(sentence: sentence, accepted: false, reason: "The checker gave no verdict on this sentence.")
        }
    }
}
