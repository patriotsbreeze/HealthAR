import Foundation

/// Decides whether every number in a sentence is backed by an allowed value of the same kind.
enum NumberBacking {
    /// What is wrong, as one plain sentence, or nil when every number and clock time is backed.
    static func problem(in reading: SentenceReading, values: BackingValues, timeZone: TimeZone,
                        config: SessionConfig) -> String? {
        if let unreadable = reading.unreadable {
            return "It has a number written as \"\(unreadable)\", which cannot be checked."
        }
        for claim in reading.numbers where !isBacked(claim, as: claim.kind, by: values, config: config) {
            return refusal(of: claim, values: values, config: config)
        }
        for clock in reading.clocks {
            let isStart = values.sessionStarts.contains { matches(clock, start: $0, timeZone: timeZone) }
            if !isStart { return "The clock time \"\(clock.written)\" is not the session start time." }
        }
        return nil
    }

    /// A written number is backed when an allowed value rounds to it at the precision it was
    /// written with. The test is "within half a unit of the last written digit", so a value
    /// exactly half way, such as 5.25, backs both "5.2" and "5.3" whichever way the writer rounds.
    static func isBacked(_ claim: NumberClaim, as kind: NumberClaim.Kind, by values: BackingValues,
                         config: SessionConfig) -> Bool {
        let unitsPerOne = pow(decimalBase, Double(claim.decimals))
        return values.candidates(for: kind).contains { candidate in
            abs(candidate - claim.value) * unitsPerOne <= halfUnit + config.roundingSlack
        }
    }

    private static func refusal(of claim: NumberClaim, values: BackingValues, config: SessionConfig) -> String {
        let own = noun(for: claim.kind)
        // The same number under another unit is the most useful thing to say: it means the
        // value is real and the unit is what went wrong.
        let elsewhere = recordedKinds.first { kind in
            noun(for: kind) != own && isBacked(claim, as: kind, by: values, config: config)
        }
        if let elsewhere, let number = claim.bareNumber {
            return "\"\(claim.written)\" is written as a \(own), but the record has \(number) only as a \(noun(for: elsewhere))."
        }
        return "The \(own) \"\(claim.written)\" is not in the record."
    }

    private static func matches(_ clock: ClockClaim, start: Date, timeZone: TimeZone) -> Bool {
        let time = ClockTime(start, in: timeZone)
        guard clock.hourOfDay == time.hour, clock.minute == time.minute else { return false }
        return clock.second == nil || clock.second == time.second
    }

    private static func noun(for kind: NumberClaim.Kind) -> String {
        switch kind {
        case .count: return "count"
        case .depthMM, .depthCM: return "depth"
        case .rate: return "rate"
        case .seconds, .minutes: return "time"
        case .percent: return "share"
        }
    }

    /// The kinds in the units the record itself is kept in. Centimetres and minutes are left out
    /// of the search for "the same number under another unit": they are conversions, and a
    /// converted value that happens to round to the number would be a misleading thing to report.
    private static let recordedKinds: [NumberClaim.Kind] = [.count(nil), .depthMM, .rate, .seconds, .percent]
    private static let decimalBase = 10.0
    private static let halfUnit = 0.5
}
