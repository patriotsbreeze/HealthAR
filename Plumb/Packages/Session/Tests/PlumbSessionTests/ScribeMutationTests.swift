import Foundation
import PlumbContracts
import Testing
@testable import PlumbSession

/// Takes sentences that are true of the fixture session, changes one number in each, and checks
/// that the checker tells the true one from the changed one every time.
@Suite struct ScribeMutationTests {
    private let fixture = ScribeFixture()

    /// A true sentence, the one number to change in it, and what to change it to.
    struct Case: Sendable, CustomTestStringConvertible {
        var text: String
        var number: String
        var changedTo: String
        /// Which entries the sentence cites.
        var cites: Cites = .firstCompression

        enum Cites: Sendable { case firstCompression, allCompressions, allPauses, secondPause, lastPause, start }

        var testDescription: String { "\(text) [\(number) -> \(changedTo)]" }

        var mutatedText: String {
            text.replacingOccurrences(of: number, with: changedTo)
        }
    }

    static let cases: [Case] = [
        Case(text: "160 compressions were recorded.", number: "160", changedTo: "150", cites: .allCompressions),
        Case(text: "Typical trusted depth was 5.3 cm.", number: "5.3", changedTo: "6.3", cites: .allCompressions),
        Case(text: "Typical trusted depth was 53 mm.", number: "53", changedTo: "63", cites: .allCompressions),
        Case(text: "The rate was 120 per minute.", number: "120", changedTo: "130", cites: .allCompressions),
        Case(text: "There were 3 pauses.", number: "3", changedTo: "4", cites: .allPauses),
        Case(text: "The longest pause lasted 9 seconds.", number: "9", changedTo: "12", cites: .allPauses),
        Case(text: "The second pause began at 51 seconds.", number: "51", changedTo: "61", cites: .secondPause),
        Case(text: "A pause lasted five seconds.", number: "five", changedTo: "six", cites: .lastPause),
        Case(text: "CPR started at 14:02.", number: "14:02", changedTo: "14:07", cites: .start),
        Case(text: "The session ran for 1 min 40 s.", number: "1 min", changedTo: "2 min", cites: .start),
        Case(text: "The session ran for 1 min 40 s.", number: "40", changedTo: "50", cites: .start),
        Case(text: "The session lasted 100 seconds.", number: "100", changedTo: "110", cites: .start),
        Case(text: "The first compression came 3 seconds after the start.", number: "3", changedTo: "8"),
        Case(text: "Depth was trusted for 80% of compressions.", number: "80", changedTo: "90"),
        Case(text: "75% of trusted compressions reached target depth.", number: "75", changedTo: "65"),
        Case(text: "Hands were on the chest 81% of the time.", number: "81", changedTo: "71"),
        Case(text: "Most trusted compressions were between 4.5 and 6 cm deep.", number: "4.5", changedTo: "3.5"),
        Case(text: "Most trusted compressions were between 4.5 and 6 cm deep.", number: "6", changedTo: "7"),
        Case(text: "160 compressions at 120 per minute with 3 pauses.", number: "120", changedTo: "102",
             cites: .allCompressions),
        Case(text: "Three pauses broke up 160 compressions.", number: "Three", changedTo: "Two", cites: .allPauses),
    ]

    private func cites(for kind: Case.Cites) -> [Int] {
        switch kind {
        case .firstCompression: return [fixture.compressionIDs[0]]
        case .allCompressions: return fixture.compressionIDs
        case .allPauses: return fixture.pauseIDs
        case .secondPause: return [fixture.pauseIDs[1]]
        case .lastPause: return [fixture.pauseIDs[2]]
        case .start: return [fixture.startID]
        }
    }

    @Test func thereAreEnoughCasesAndEachChangesExactlyOneNumber() {
        #expect(Self.cases.count >= 10)
        for item in Self.cases {
            #expect(item.text.components(separatedBy: item.number).count == 2,
                    "\"\(item.number)\" should appear exactly once in \"\(item.text)\"")
            #expect(item.mutatedText != item.text)
        }
    }

    @Test(arguments: ScribeMutationTests.cases)
    func theTrueSentenceIsAcceptedAndTheChangedOneRefused(item: Case) {
        let cited = cites(for: item.cites)
        expectAccepted(fixture.verdict(item.text, cites: cited))

        let mutated = fixture.verdict(item.mutatedText, cites: cited)
        #expect(!mutated.accepted, "\"\(item.mutatedText)\" was accepted")
        #expect(mutated.reason?.isEmpty == false)
    }

    /// A wider sweep: every number written in digits in every true sentence is pushed up, one
    /// number at a time, and every result must be refused. The amounts are chosen so that no
    /// pushed-up number lands on another value the record really holds.
    @Test func everyDigitNumberPushedUpIsRefused() {
        var checked = 0
        for item in Self.cases {
            let cited = cites(for: item.cites)
            for (range, written) in digitRuns(in: item.text) {
                for delta in [11, 17, 29] {
                    let text = item.text.replacingCharacters(in: range, with: pushedUp(written, by: delta))
                    let verdict = fixture.verdict(text, cites: cited)
                    #expect(!verdict.accepted, "\"\(text)\" was accepted")
                    checked += 1
                }
            }
        }
        #expect(checked >= 60)
    }

    /// Runs of digits, with a decimal part when there is one, and where they sit in the text.
    private func digitRuns(in text: String) -> [(Range<String.Index>, String)] {
        var runs: [(Range<String.Index>, String)] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index].isPlainDigit else {
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, text[end].isPlainDigit { end = text.index(after: end) }
            if end < text.endIndex, text[end] == ".", text.index(after: end) < text.endIndex,
               text[text.index(after: end)].isPlainDigit {
                end = text.index(after: end)
                while end < text.endIndex, text[end].isPlainDigit { end = text.index(after: end) }
            }
            runs.append((index..<end, String(text[index..<end])))
            index = end
        }
        return runs
    }

    /// Adds to the whole part and leaves the rest as written: 5.3 becomes 16.3, and the minutes
    /// of 14:02 become 13, keeping two digits.
    private func pushedUp(_ written: String, by delta: Int) -> String {
        let parts = written.split(separator: ".", maxSplits: 1)
        let whole = String((Int(parts[0]) ?? 0) + delta)
        let padded = String(repeating: "0", count: max(0, parts[0].count - whole.count)) + whole
        return parts.count == 2 ? "\(padded).\(parts[1])" : padded
    }
}
