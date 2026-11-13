/// Finds every number in a sentence and works out, from the words around it, what it claims to be.
enum NumberClaimReader {
    static func read(_ tokens: [SentenceToken], config: SessionConfig) -> SentenceReading {
        var reading = SentenceReading()
        var drafts: [Draft] = []
        for (index, token) in tokens.enumerated() {
            switch token.kind {
            case .number(let value, let decimals):
                // "3/4" is a share, not two counts, and a share written that way cannot be checked.
                if tokens.mark(index + 1) == NumberWords.fractionSlash, tokens.isNumber(index + 2) {
                    reading.unreadable = reading.unreadable
                        ?? "\(token.written)\(NumberWords.fractionSlash)\(tokens[index + 2].written)"
                }
                drafts.append(draft(value: value, decimals: decimals, at: index, in: tokens, config: config))
            case .word(let word):
                if let value = NumberWords.values[word] {
                    drafts.append(draft(value: value, decimals: 0, at: index, in: tokens, config: config))
                } else if NumberWords.unreadable.contains(word) {
                    reading.unreadable = reading.unreadable ?? token.written
                } else if let value = NumberWords.nounBound[word],
                          let noun = UnitReader.countNoun(after: index, in: tokens, reach: config.countNounReach) {
                    drafts.append(Draft(value: value, decimals: 0, written: token.written, numberIndex: index,
                                        end: index + 1, kind: .count(noun)))
                }
            case .clock(let hour, let minute, let second):
                let meridiem = tokens.word(index + 1).flatMap { UnitWords.meridiems[$0] }
                reading.clocks.append(ClockClaim(hour: hour, minute: minute, second: second,
                                                 meridiem: meridiem, written: token.written))
            case .oddDigit:
                reading.unreadable = reading.unreadable ?? token.written
            case .mark:
                break
            }
        }
        shareUnits(across: &drafts, in: tokens)
        reading.numbers = claims(from: drafts, in: tokens)
        return reading
    }

    /// A number while its kind is still being worked out.
    private struct Draft {
        var value: Double
        var decimals: Int
        var written: String
        var numberIndex: Int
        /// Index just past the number and the unit words that belong to it.
        var end: Int
        /// Nil until a unit, a counted noun or a neighbouring number settles it.
        var kind: NumberClaim.Kind?
    }

    private static func draft(value: Double, decimals: Int, at index: Int, in tokens: [SentenceToken],
                              config: SessionConfig) -> Draft {
        var draft = Draft(value: value, decimals: decimals, written: tokens[index].written,
                          numberIndex: index, end: index + 1, kind: nil)
        if let (kind, end) = UnitReader.unit(at: index + 1, in: tokens) {
            draft.kind = kind
            draft.end = end
        } else if let noun = UnitReader.countNoun(after: index, in: tokens, reach: config.countNounReach) {
            draft.kind = .count(noun)
        }
        return draft
    }

    // MARK: Numbers that belong together

    /// "4.5 to 5.5 cm": a number with no unit of its own takes the unit of the number it is linked to.
    private static func shareUnits(across drafts: inout [Draft], in tokens: [SentenceToken]) {
        guard drafts.count > 1 else { return }
        for index in (0..<(drafts.count - 1)).reversed() where drafts[index].kind == nil {
            let between = tokens[drafts[index].end..<drafts[index + 1].numberIndex]
            if !between.isEmpty, between.allSatisfy(isRangeLink) {
                drafts[index].kind = drafts[index + 1].kind
            }
        }
    }

    private static func claims(from drafts: [Draft], in tokens: [SentenceToken]) -> [NumberClaim] {
        var claims: [NumberClaim] = []
        var index = 0
        while index < drafts.count {
            if index + 1 < drafts.count,
               let whole = minutesAndSeconds(drafts[index], drafts[index + 1], in: tokens) {
                claims.append(whole)
                index += 2
            } else {
                claims.append(claim(from: drafts[index]))
                index += 1
            }
        }
        return claims
    }

    /// "6 min 40 s" is one length of time, checked as 400 seconds, not two separate numbers.
    private static func minutesAndSeconds(_ minutes: Draft, _ seconds: Draft,
                                          in tokens: [SentenceToken]) -> NumberClaim? {
        guard minutes.kind == .minutes, minutes.decimals == 0, seconds.kind == .seconds,
              seconds.value < Units.secondsPerMinute, minutes.end <= seconds.numberIndex,
              tokens[minutes.end..<seconds.numberIndex].allSatisfy(isJoin) else { return nil }
        return NumberClaim(value: minutes.value * Units.secondsPerMinute + seconds.value,
                           decimals: seconds.decimals, kind: .seconds,
                           written: "\(minutes.written) min \(seconds.written) s", bareNumber: nil)
    }

    private static func claim(from draft: Draft) -> NumberClaim {
        let kind = draft.kind ?? .count(nil)
        return NumberClaim(value: draft.value, decimals: draft.decimals, kind: kind,
                           written: written(draft.written, as: kind), bareNumber: draft.written)
    }

    private static func written(_ number: String, as kind: NumberClaim.Kind) -> String {
        switch kind {
        case .count(nil): return number
        case .count(.compressions): return "\(number) compressions"
        case .count(.pauses): return "\(number) pauses"
        case .depthMM: return "\(number) mm"
        case .depthCM: return "\(number) cm"
        case .rate: return "\(number) per minute"
        case .seconds: return "\(number) s"
        case .minutes: return "\(number) min"
        case .percent: return "\(number)%"
        }
    }

    private static func isRangeLink(_ token: SentenceToken) -> Bool {
        switch token.kind {
        case .word(let word): return UnitWords.rangeWords.contains(word)
        case .mark(let mark): return UnitWords.rangeMarks.contains(mark)
        case .number, .clock, .oddDigit: return false
        }
    }

    private static func isJoin(_ token: SentenceToken) -> Bool {
        switch token.kind {
        case .word(let word): return UnitWords.joinWords.contains(word)
        case .mark(let mark): return UnitWords.joinMarks.contains(mark)
        case .number, .clock, .oddDigit: return false
        }
    }
}
