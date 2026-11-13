import Foundation
import PlumbContracts
import Testing
@testable import PlumbSession

/// What cited compressions do and do not back. They come two a second, so they are read as a
/// group: citing a long run of them must not turn every number of seconds or millimetres true.
@Suite struct ScribeCitedGroupTests {
    private let fixture = ScribeFixture()

    @Test func citingEveryCompressionDoesNotBackEveryTimeOrDepth() {
        let everything = fixture.compressionIDs
        // A compression really did happen at 12 s, and one really was 52 mm deep.
        expectRefused(fixture.verdict("The longest pause lasted 12 seconds.", cites: everything), mentioning: "12 s")
        expectRefused(fixture.verdict("Compressions stopped at 40 seconds.", cites: everything), mentioning: "40 s")
        expectRefused(fixture.verdict("Typical depth was 5.2 cm.", cites: everything), mentioning: "5.2 cm")
        // An untrusted compression read 70 mm; citing it among the rest changes nothing.
        expectRefused(fixture.verdict("Depth reached 70 mm.", cites: everything), mentioning: "70 mm")
    }

    @Test func aCitedRunBacksWhenItBeganAndEnded() {
        // The second run of 40 compressions: 31.5 s to 51 s.
        let secondRun = Array(fixture.compressionIDs[40..<80])
        expectAccepted(fixture.verdict("That run began at 31.5 seconds.", cites: secondRun))
        expectAccepted(fixture.verdict("That run began at 31.5 seconds and ended at 51 seconds.", cites: secondRun))
        expectRefused(fixture.verdict("That run began at 31.5 seconds."), mentioning: "31.5 s")
        expectRefused(fixture.verdict("That run began at 40 seconds.", cites: secondRun), mentioning: "40 s")
    }

    @Test func aCitedRunBacksItsOwnTypicalDepth() {
        // Compressions 2, 3 and 4 are 52, 54 and 58 mm deep, all trusted: the middle one is 54.
        // Compression 5 was measured while depth was not trusted, so citing it too changes nothing.
        let ids = fixture.compressionIDs
        expectAccepted(fixture.verdict("Those strokes were typically 54 mm deep.", cites: Array(ids[1...3])))
        expectAccepted(fixture.verdict("Those strokes were typically 54 mm deep.", cites: Array(ids[1...4])))
        expectRefused(fixture.verdict("Those strokes were typically 56 mm deep.", cites: Array(ids[1...4])),
                      mentioning: "56 mm")
    }

    @Test func aCitedRunBacksItsOwnRateOnlyWithTwoGapsOrMore() {
        // Six compressions; the last two came faster. Gaps: 0.5, 0.5, 0.5, 0.4, 0.4 seconds.
        // The session's typical gap is 0.5 s (120 a minute); the last two alone give 150 a minute.
        let log = numbered([
            (0, .system, .sessionStarted(wallClock: fixtureStart)),
            (1.0, .measured, .compression(stroke(1, at: 1.0, depth: 50, interval: nil))),
            (1.5, .measured, .compression(stroke(2, at: 1.5, depth: 50, interval: 0.5))),
            (2.0, .measured, .compression(stroke(3, at: 2.0, depth: 50, interval: 0.5))),
            (2.5, .measured, .compression(stroke(4, at: 2.5, depth: 50, interval: 0.5))),
            (2.9, .measured, .compression(stroke(5, at: 2.9, depth: 50, interval: 0.4))),
            (3.3, .measured, .compression(stroke(6, at: 3.3, depth: 50, interval: 0.4))),
        ])
        let stats = HandoffCalculator.stats(log: log, endT: 4)
        #expect(stats.ratePerMin == 120)

        func accepted(_ text: String, cites: [Int]) -> Bool {
            ScribeVerifier.verify([ScribeSentence(text: text, cites: cites)], log: log, stats: stats,
                                  timeZone: .gmt)[0].accepted
        }
        let fast = "The last strokes ran at 150 per minute."
        #expect(accepted(fast, cites: [6, 7]))
        #expect(!accepted(fast, cites: [7]))
        #expect(!accepted(fast, cites: [2, 3, 4, 5, 6, 7]))
        #expect(accepted("The rate was 120 per minute.", cites: [7]))
    }
}
