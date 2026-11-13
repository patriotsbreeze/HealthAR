import Foundation
import PlumbContracts
import Testing
@testable import PlumbSession

@Suite struct ScribeVerifierAcceptTests {
    private let fixture = ScribeFixture()

    /// The numbers every sentence in these tests is written against. If the fixture drifts,
    /// this fails first and says why.
    @Test func theFixtureHoldsTheNumbersTheSentencesUse() {
        let stats = fixture.stats
        #expect(stats.compressions == 160)
        #expect(stats.ratePerMin == 120)
        #expect(stats.depthMM == 53)
        #expect(stats.depthLowMM == 47)
        #expect(stats.depthHighMM == 58)
        #expect(HandoffText.depthRange(stats) == "4.5 to 6 cm")
        #expect(stats.trustedFraction == 0.8)
        #expect(stats.reachedTargetFraction == 0.75)
        #expect(HandoffText.percent(stats.handsOnFraction) == "81%")
        #expect(stats.pauses.map(\.start) == [22.5, 51, 74.5])
        #expect(stats.pauses.map(\.durationS) == [9, 4, 5])
        #expect(stats.longestPauseS == 9)
        #expect(stats.timeToFirstCompressionS == 3)
        #expect(stats.durationS == 100)
        #expect(HandoffText.headline(stats, timeZone: ScribeFixture.zone)
            == "CPR started 14:02. Ran 1 min 40 s. 3 pauses, longest 9 s.")
        #expect(fixture.compressionIDs.count == 160)
        #expect(fixture.pauseIDs.count == 3)
    }

    @Test func acceptsCountDepthAndRateCitingTheCompressions() {
        let verdict = fixture.verdict("160 compressions were recorded, typically 5.3 cm deep at 120 per minute.",
                                      cites: fixture.compressionIDs)
        expectAccepted(verdict)
    }

    @Test func acceptsTheLongestPauseInSeconds() {
        expectAccepted(fixture.verdict("The longest pause lasted 9 seconds.", cites: [fixture.pauseIDs[0]]))
    }

    @Test func acceptsTheSameNumbersSpelledOut() {
        let lastPause = [fixture.pauseIDs[2]]
        expectAccepted(fixture.verdict("A pause of 5 seconds was recorded.", cites: lastPause))
        expectAccepted(fixture.verdict("A pause of five seconds was recorded.", cites: lastPause))
        expectAccepted(fixture.verdict("There were 3 pauses, the longest 9 seconds.", cites: fixture.pauseIDs))
        expectAccepted(fixture.verdict("There were three pauses, the longest nine seconds.", cites: fixture.pauseIDs))
        expectAccepted(fixture.verdict("The first compression came Three seconds in."))
    }

    @Test(arguments: [
        "CPR started 14:02 and ran 1 min 40 s with 3 pauses, the longest 9 s.",
        "CPR started at 2:02 pm.",
        "The session started at 14:02:10.",
        "The session ran for 1 minute and 40 seconds.",
        "The session ran for 100 seconds.",
        "The session ran for 1.7 minutes.",
        "The session ran for about 2 minutes.",
        "Most trusted compressions were between 4.5 and 6 cm deep.",
        "Trusted depth ran from 4.5–6 cm.",
        "Trusted depth ran from 47 to 58 mm.",
        "Typical trusted depth was 53 millimetres.",
        "Typical trusted depth was 5 cm.",
        "Typical trusted depth was 5.3cm at 120/min.",
        "The longest pause lasted 9s.",
        "The rate was 120 compressions per minute.",
        "The rate was 120/min.",
        "A 9-second pause was the longest.",
        "Pauses lasted 9, 4 and 5 seconds.",
        "Depth was trusted for 80% of compressions.",
        "75 percent of trusted compressions reached target depth.",
        "Hands were on the chest 81 per cent of the time.",
        "The rhythm steadied after the second pause.",
        "Breathing and medicines were not recorded.",
        "160 compressions, 3 pauses",
    ])
    func acceptsTrueSentencesInManyWordings(text: String) {
        expectAccepted(fixture.verdict(text, cites: [fixture.startID] + fixture.pauseIDs))
    }

    @Test func acceptsValuesThatComeOnlyFromACitedEntry() {
        // The second pause ended at 55 s. That moment is in the cited entry, not in the stats.
        expectAccepted(fixture.verdict("Compressions resumed at 55 seconds.", cites: [fixture.pauseIDs[1]]))
        expectRefused(fixture.verdict("Compressions resumed at 55 seconds.", cites: [fixture.pauseIDs[0]]),
                      mentioning: "55 s")
        // A single trusted compression's own depth.
        expectAccepted(fixture.verdict("That compression was 52 mm deep.", cites: [fixture.compressionIDs[1]]))
        expectRefused(fixture.verdict("That compression was 52 mm deep.", cites: [fixture.compressionIDs[0]]),
                      mentioning: "52 mm")
    }

    @Test func acceptsEitherWayOfRoundingAHalf() {
        let log = numbered([(0, .system, .sessionStarted(wallClock: fixtureStart))])
        let stats = HandoffStats(compressions: 4, depthMM: 52.5)
        let texts = ["Typical depth was 5.2 cm.", "Typical depth was 5.3 cm.", "Typical depth was 5.25 cm.",
                     "Typical depth was 5.1 cm.", "Typical depth was 5.4 cm."]
        let verdicts = ScribeVerifier.verify(texts.map { ScribeSentence(text: $0, cites: [1]) }, log: log,
                                             stats: stats, maxSentences: 5, timeZone: .gmt)
        #expect(verdicts.map(\.accepted) == [true, true, true, false, false])
    }

    @Test func clockTimesAreReadInTheGivenZone() throws {
        let india = try #require(TimeZone(secondsFromGMT: 5 * 3600 + 30 * 60))
        let sentences = [ScribeSentence(text: "CPR started at 19:32.", cites: [1]),
                         ScribeSentence(text: "CPR started at 14:02.", cites: [1])]
        let there = ScribeVerifier.verify(sentences, log: fixture.log, stats: fixture.stats, timeZone: india)
        let here = ScribeVerifier.verify(sentences, log: fixture.log, stats: fixture.stats, timeZone: .gmt)
        #expect(there.map(\.accepted) == [true, false])
        #expect(here.map(\.accepted) == [false, true])
    }

    @Test func theDefaultZoneIsTheOneTheHeadlineUses() {
        // The headline and the checker both default to the device's zone, so a sentence that
        // repeats the headline's start time passes wherever the tests run.
        let headline = HandoffText.headline(fixture.stats)
        let verdicts = ScribeVerifier.verify([ScribeSentence(text: headline, cites: [1])], log: fixture.log,
                                             stats: fixture.stats)
        // The headline is three sentences, so as one "sentence" it is refused for its shape,
        // but its first sentence on its own is accepted.
        expectRefused(verdicts[0], mentioning: "more than one sentence")
        let first = String(headline.prefix { $0 != "." }) + "."
        let alone = ScribeVerifier.verify([ScribeSentence(text: first, cites: [1])], log: fixture.log,
                                          stats: fixture.stats)
        expectAccepted(alone[0])
    }

    @Test func verdictsKeepTheOrderAndLengthOfTheInput() {
        let sentences = [
            ScribeSentence(text: "160 compressions were recorded.", cites: fixture.compressionIDs),
            ScribeSentence(text: "170 compressions were recorded.", cites: fixture.compressionIDs),
            ScribeSentence(text: "There were 3 pauses.", cites: fixture.pauseIDs),
        ]
        let verdicts = fixture.verify(sentences)
        #expect(verdicts.map(\.sentence) == sentences)
        #expect(verdicts.map(\.accepted) == [true, false, true])
        #expect(verdicts.map { $0.reason == nil } == [true, false, true])
        #expect(fixture.verify([]).isEmpty)
    }

    @Test func theSameInputAlwaysGivesTheSameVerdicts() {
        let sentences = [
            ScribeSentence(text: "160 compressions were recorded.", cites: fixture.compressionIDs),
            ScribeSentence(text: "The patient survived.", cites: [1]),
            ScribeSentence(text: "Typical depth was 9 cm.", cites: [1]),
        ]
        let first = fixture.verify(sentences)
        for _ in 0..<5 {
            #expect(fixture.verify(sentences) == first)
        }
    }
}
