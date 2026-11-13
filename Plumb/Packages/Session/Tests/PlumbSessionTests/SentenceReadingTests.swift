import Foundation
import Testing
@testable import PlumbSession

/// How the checker reads a sentence, tested below the level of whole verdicts.
@Suite struct SentenceReadingTests {
    private func kinds(_ text: String) -> [SentenceToken.Kind] {
        SentenceScanner.tokens(in: text).map(\.kind)
    }

    private func read(_ text: String) -> SentenceReading {
        NumberClaimReader.read(SentenceScanner.tokens(in: text), config: .standard)
    }

    private func claims(_ text: String) -> [String] {
        read(text).numbers.map(\.written)
    }

    // MARK: Scanner

    @Test func scannerSplitsWordsNumbersClocksAndMarks() {
        #expect(kinds("Ran 6 min, 5.30 cm at 14:02!") == [
            .word("ran"), .number(6, decimals: 0), .word("min"), .mark(","), .number(5.3, decimals: 2),
            .word("cm"), .word("at"), .clock(hour: 14, minute: 2, second: nil), .mark("!"),
        ])
    }

    @Test func scannerSeparatesDigitsFromLettersGluedToThem() {
        #expect(kinds("9s 5cm 83% 110/min") == [
            .number(9, decimals: 0), .word("s"), .number(5, decimals: 0), .word("cm"),
            .number(83, decimals: 0), .mark("%"), .number(110, decimals: 0), .mark("/"), .word("min"),
        ])
    }

    @Test func scannerReadsThousandsGroupsButNotLists() {
        #expect(kinds("1,200") == [.number(1200, decimals: 0)])
        #expect(kinds("12,345,678.5") == [.number(12_345_678.5, decimals: 1)])
        #expect(kinds("3, 200") == [.number(3, decimals: 0), .mark(","), .number(200, decimals: 0)])
        #expect(kinds("5,3") == [.number(5, decimals: 0), .mark(","), .number(3, decimals: 0)])
        #expect(kinds("1,2000") == [.number(1, decimals: 0), .mark(","), .number(2000, decimals: 0)])
    }

    @Test func scannerReadsClockTimesOnlyInClockShape() {
        #expect(kinds("14:02:31") == [.clock(hour: 14, minute: 2, second: 31)])
        #expect(kinds("9:05") == [.clock(hour: 9, minute: 5, second: nil)])
        // A ratio is two numbers, not a time.
        #expect(kinds("30:2") == [.number(30, decimals: 0), .mark(":"), .number(2, decimals: 0)])
        #expect(kinds("140:02") == [.number(140, decimals: 0), .mark(":"), .number(2, decimals: 0)])
    }

    @Test func scannerFoldsCaseAndAccents() {
        #expect(kinds("Décès DEAD de\u{0301}ad") == [.word("deces"), .word("dead"), .word("dead")])
    }

    @Test func scannerFlagsDigitsItCannotRead() {
        #expect(kinds("½") == [.oddDigit])
        #expect(kinds("٣") == [.oddDigit])
        #expect(kinds("x²") == [.word("x"), .oddDigit])
    }

    @Test func aFullStopAfterANumberIsNotADecimalPoint() {
        #expect(kinds("at 120.") == [.word("at"), .number(120, decimals: 0), .mark(".")])
    }

    // MARK: Units

    @Test(arguments: [
        ("5.3 cm", "5.3 cm"), ("5.3 centimetres", "5.3 cm"), ("5.3 centimeters", "5.3 cm"), ("53 mm", "53 mm"),
        ("53 millimetres", "53 mm"), ("9 s", "9 s"), ("9 sec", "9 s"), ("9 seconds", "9 s"),
        ("a 9-second pause", "9 s"), ("7 min", "7 min"), ("7 minutes", "7 min"), ("83%", "83%"),
        ("83 %", "83%"), ("83 percent", "83%"), ("83 per cent", "83%"), ("110 per minute", "110 per minute"),
        ("110 a minute", "110 per minute"), ("110/min", "110 per minute"), ("110 bpm", "110 per minute"),
        ("110 compressions per minute", "110 per minute"), ("110 pushes a minute", "110 per minute"),
        ("160 compressions", "160 compressions"), ("160 chest compressions", "160 compressions"),
        ("3 pauses", "3 pauses"), ("3 long pauses", "3 pauses"), ("no pauses", "no pauses"),
        ("no compressions", "no compressions"), ("both pauses", "both pauses"),
        ("a single long pause", "single pauses"), ("160", "160"), ("paused 3 times", "3"), ("9 m", "9"),
    ])
    func readsTheUnitAfterANumber(text: String, expected: String) {
        #expect(claims(text) == [expected])
    }

    @Test func aNumberLinkedToAnotherSharesItsUnit() {
        #expect(claims("4.5 to 5.5 cm") == ["4.5 cm", "5.5 cm"])
        #expect(claims("between 4.5 and 5.5 cm") == ["4.5 cm", "5.5 cm"])
        #expect(claims("4.5-5.5 cm") == ["4.5 cm", "5.5 cm"])
        #expect(claims("4.5–5.5 cm") == ["4.5 cm", "5.5 cm"])
        #expect(claims("9, 4 and 5 seconds") == ["9 s", "4 s", "5 s"])
        #expect(claims("2 to 3 pauses") == ["2 pauses", "3 pauses"])
    }

    @Test func numbersWithTheirOwnMeaningAreNotLinked() {
        #expect(claims("160 compressions and 3 pauses") == ["160 compressions", "3 pauses"])
        #expect(claims("160 compressions at 120 per minute") == ["160 compressions", "120 per minute"])
        #expect(claims("3 pauses, 9 s the longest") == ["3 pauses", "9 s"])
        #expect(claims("160 then 9 s") == ["160", "9 s"])
    }

    @Test func minutesAndSecondsAreOneLengthOfTime() {
        #expect(read("6 min 40 s").numbers == [
            NumberClaim(value: 400, decimals: 0, kind: .seconds, written: "6 min 40 s", bareNumber: nil),
        ])
        #expect(claims("6 minutes and 40 seconds") == ["6 min 40 s"])
        #expect(claims("6 minutes, 40 seconds") == ["6 min 40 s"])
        #expect(read("1 min 2.5 s").numbers.map(\.value) == [62.5])
        #expect(read("1 min 2.5 s").numbers.map(\.decimals) == [1])
        // Sixty or more seconds is not the seconds part of a time, and words in between break the pair.
        #expect(claims("1 min 75 s") == ["1 min", "75 s"])
        #expect(claims("6 minutes with a 40 second pause") == ["6 min", "40 s"])
        #expect(claims("1.5 min 20 s") == ["1.5 min", "20 s"])
    }

    @Test func spelledNumbersAreNumbers() {
        #expect(read("five seconds").numbers == [
            NumberClaim(value: 5, decimals: 0, kind: .seconds, written: "five s", bareNumber: "five"),
        ])
        #expect(read("Twelve pauses").numbers.map(\.value) == [12])
        #expect(read("zero pauses").numbers.map(\.kind) == [.count(.pauses)])
        #expect(read("paused twice").numbers.map(\.value) == [2])
        #expect(read("the second pause").numbers.isEmpty)
        #expect(read("no depth was recorded").numbers.isEmpty)
    }

    @Test func numberWordsItCannotReadAreReported() {
        #expect(read("twenty pauses").unreadable == "twenty")
        #expect(read("a Dozen pauses").unreadable == "Dozen")
        #expect(read("half the time").unreadable == "half")
        #expect(read("3 pauses and ½ more").unreadable == "½")
        #expect(read("3/4 of compressions").unreadable == "3/4")
        #expect(read("VIII pauses").unreadable == "VIII")
        #expect(read("the rate doubled").unreadable == "doubled")
        #expect(read("110/min").unreadable == nil)
        #expect(read("3 pauses").unreadable == nil)
    }

    @Test func clockTimesCarryAmAndPm() {
        #expect(read("at 2:02 pm").clocks.map(\.hourOfDay) == [14])
        #expect(read("at 2:02 AM").clocks.map(\.hourOfDay) == [2])
        #expect(read("at 12:15 am").clocks.map(\.hourOfDay) == [0])
        #expect(read("at 12:15 pm").clocks.map(\.hourOfDay) == [12])
        #expect(read("at 14:02").clocks.map(\.hourOfDay) == [14])
        #expect(read("at 14:02 pm").clocks.map(\.hourOfDay) == [nil])
        #expect(read("at 14:02").numbers.isEmpty)
    }

    // MARK: Shape and words

    @Test func wordCountCountsWordsNumbersAndClockTimes() {
        #expect(SentenceShape.wordCount(SentenceScanner.tokens(in: "Ran 6 min 40 s, from 14:02 (hands-on 81%).")) == 10)
    }

    @Test func decimalsAndClosingQuotesDoNotEndASentence() {
        let config = SessionConfig.standard
        func problem(_ text: String) -> String? {
            SentenceShape.problem(in: text, tokens: SentenceScanner.tokens(in: text), config: config)
        }
        #expect(problem("Depth was 5.3 cm.") == nil)
        #expect(problem("Depth was 5.3 cm") == nil)
        #expect(problem("The cue was \"push harder.\"") == nil)
        #expect(problem("Depth was 5.3 cm!!") == nil)
        #expect(problem("Depth was 5. 3 cm.") == "It is more than one sentence.")
        #expect(problem("Depth was 53mm at 14:02pm.") == nil)
        #expect(problem("Depth was d33p.") == "It mixes digits into a word, which the word checks cannot read.")
        #expect(problem("Depth was fine. Rate too.") == "It is more than one sentence.")
        #expect(problem("Depth was fine… rate too.") == "It is more than one sentence.")
    }

    @Test func bannedStemsFitWordsByTheirStart() {
        let config = SessionConfig.standard
        #expect(BannedIdeas.fits("diagnostic", stem: "diagnos", config: config))
        #expect(BannedIdeas.fits("misdiagnosed", stem: "diagnos", config: config))
        #expect(BannedIdeas.fits("mg", stem: "mg", config: config))
        #expect(!BannedIdeas.fits("mgmt", stem: "mg", config: config))
        #expect(!BannedIdeas.fits("often", stem: "of", config: config))
        #expect(!BannedIdeas.fits("steadied", stem: "died", config: config))
        #expect(!BannedIdeas.fits("impulse", stem: "pulse", config: config))
        #expect(!BannedIdeas.fits("because", stem: "cause", config: config))
    }

    @Test func aNumberBetweenWordsBreaksAPhrase() {
        let words = WordSequence.words(of: SentenceScanner.tokens(in: "heart 2 attack, heart-attack"))
        #expect(words == ["heart", nil, "attack", "heart", "attack"])
        #expect(WordSequence.firstRun(in: ["heart", nil, "attack"], fitting: ["heart", "attack"], by: ==) == nil)
        #expect(WordSequence.firstRun(in: words, fitting: ["heart", "attack"], by: ==) == ["heart", "attack"])
        #expect(WordSequence.firstRun(in: ["heart"], fitting: ["heart", "attack"], by: ==) == nil)
    }
}
