import Foundation
import PlumbContracts

/// Everything the scribe model is told. Kept apart from the loop so the wording can be read and
/// reviewed on its own.
enum ScribePrompt {
    /// The standing rules. The model writes a record; it never instructs anyone.
    static func system(config: AgentsConfig) -> String {
        """
        You write part of the record of a CPR training simulation. A person practised chest \
        compressions on a manikin while a phone measured the movement. Nobody was treated. This is \
        not a medical record and you are not giving anyone instructions: every instruction in this \
        simulation is a fixed phrase chosen by on-device rules, never by you.

        Write at most \(config.scribeMaxSentences) sentences. Each one is a neutral statement of what \
        was measured: counts, rate, depth range, pauses and timing. Nothing else.

        Rules:
        - Use only numbers that appear in the data you are given, copied exactly as written. Do not \
        round, convert, add, subtract or average them. Any other number is forbidden.
        - Each sentence is exactly one sentence of at most \(config.scribeMaxWords) words.
        - Each sentence lists in "cites" the ids of the log entries it rests on. Only the listed ids exist.
        - No advice, instructions or recommendations.
        - No causes and no explanations of why anything happened.
        - No outcomes and no predictions.
        - No praise and no blame.
        - No diagnosis, and nothing about the condition of any person.
        - Never mention survival, pulse, breathing, drugs or medication.
        - Where the data says "not recorded", state no value for it.
        - Do not restate the headline.

        Every sentence is checked automatically against the log, number by number. A sentence that \
        fails the check is discarded and never shown.

        Answer with JSON only, in this form: {"sentences": [{"text": "…", "cites": [1, 2]}]}
        """
    }

    /// The data for the first request: the headline, the measured summary and the log lines.
    static func brief(headline: String, stats: HandoffStats, digest: ScribeLogDigest, stride: Int) -> String {
        var sections = [
            "HEADLINE ALREADY SHOWN\n\(Scrubber.flatten(headline, limit: 300))",
            "MEASURED SUMMARY\n\(summary(of: stats))",
            "LOG ENTRIES\n\(digest.lines.joined(separator: "\n"))",
        ]
        if digest.thinned {
            sections.append("""
            NOTE
            The log has \(digest.usableCount) entries, too many to list. The list above holds every \
            pause, one compression in every \(stride), the first and last compression and the first and \
            last entry. Counts and typical values for the whole session are in the measured summary.
            """)
        }
        return sections.joined(separator: "\n\n")
    }

    /// The data for the second request: the first brief plus what was refused and why.
    static func replacementBrief(_ brief: String, kept: [ScribeSentence], refused: [ScribeVerdict]) -> String {
        let keptLines = kept.isEmpty ? "none" : kept.map { "- \($0.text)" }.joined(separator: "\n")
        let refusedLines = refused.enumerated().map { index, verdict in
            "\(index + 1). \"\(verdict.sentence.text)\" was refused: \(verdict.reason ?? "no reason given")"
        }.joined(separator: "\n")
        return """
        \(brief)

        ALREADY ACCEPTED, DO NOT REPEAT
        \(keptLines)

        REFUSED BY THE AUTOMATIC CHECK
        \(refusedLines)

        Write exactly \(refused.count) replacement sentence(s), one for each refused sentence, in the \
        same order, and nothing else. Each replacement must avoid the stated reason for refusal.
        """
    }

    /// The answer's shape. `cites` may only hold ids that were shown, so a model cannot cite an
    /// entry that does not exist.
    static func schema(ids: [Int], maxSentences: Int, maxWords: Int) -> JSONValue {
        let sentence = JSONSchema.object([
            "text": JSONSchema.string(description: "One neutral sentence of at most \(maxWords) words."),
            "cites": JSONSchema.array(of: JSONSchema.integer(oneOf: ids), minItems: 1),
        ], required: ["text", "cites"])
        return JSONSchema.object(["sentences": JSONSchema.array(of: sentence, maxItems: maxSentences)],
                                 required: ["sentences"])
    }

    // MARK: - Private

    /// The stats as labelled lines. Numbers are written the way a sentence would say them, so the
    /// model can copy them and the checker can find them. A missing value reads "not recorded".
    private static func summary(of stats: HandoffStats) -> String {
        func value(_ number: Double?, _ unit: String) -> String {
            number.map { "\($0.oneDecimal) \(unit)" } ?? "not recorded"
        }
        func percent(_ fraction: Double?, of whole: String) -> String {
            fraction.map { "\(Int(($0 * 100).rounded())) percent of \(whole)" } ?? "not recorded"
        }
        let range: String
        if let low = stats.depthLowMM, let high = stats.depthHighMM {
            range = "\(low.oneDecimal) to \(high.oneDecimal) mm"
        } else {
            range = "not recorded"
        }
        var lines = [
            "Session length: \(stats.durationS.oneDecimal) s",
            "Time to first compression: \(value(stats.timeToFirstCompressionS, "s"))",
            "Compressions counted: \(stats.compressions)",
            "Typical rate: \(value(stats.ratePerMin, "per minute"))",
            "Typical depth: \(value(stats.depthMM, "mm"))",
            "Depth range of most trusted compressions: \(range)",
            "Reached the target depth: \(percent(stats.reachedTargetFraction, of: "trusted compressions"))",
            "Depth was trusted for: \(percent(stats.trustedFraction, of: "all compressions"))",
            "Compressing for: \(percent(stats.handsOnFraction, of: "the time since the first compression"))",
            "Pauses: \(stats.pauses.count)",
            "Longest pause: \(value(stats.longestPauseS, "s"))",
        ]
        lines += stats.pauses.map { "Pause starting at \($0.start.oneDecimal) s lasting \($0.durationS.oneDecimal) s" }
        if !stats.notRecorded.isEmpty {
            lines.append("Not recorded by this app: \(stats.notRecorded.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}
