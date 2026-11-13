import Foundation
import PlumbContracts
import Testing
@testable import PlumbSession

@Suite struct ScribeVerifierRefuseTests {
    private let fixture = ScribeFixture()

    // MARK: Numbers

    @Test func refusesAWrongCount() {
        let verdict = fixture.verdict("170 compressions were recorded.", cites: fixture.compressionIDs)
        expectRefused(verdict, mentioning: "The count \"170 compressions\" is not in the record.")
        expectRefused(fixture.verdict("There were 4 pauses.", cites: fixture.pauseIDs), mentioning: "4 pauses")
    }

    @Test func refusesADepthOffByOneCentimetre() {
        expectRefused(fixture.verdict("Typical trusted depth was 6.3 cm.", cites: fixture.compressionIDs),
                      mentioning: "The depth \"6.3 cm\" is not in the record.")
        expectRefused(fixture.verdict("Typical trusted depth was 4.3 cm.", cites: fixture.compressionIDs),
                      mentioning: "4.3 cm")
        expectRefused(fixture.verdict("Typical trusted depth was 63 mm.", cites: fixture.compressionIDs),
                      mentioning: "63 mm")
    }

    @Test func refusesARateOffByTen() {
        expectRefused(fixture.verdict("The rate was 130 per minute.", cites: fixture.compressionIDs),
                      mentioning: "The rate \"130 per minute\" is not in the record.")
        expectRefused(fixture.verdict("The rate was 110 compressions per minute.", cites: fixture.compressionIDs),
                      mentioning: "110 per minute")
    }

    @Test func refusesAMadeUpPercentage() {
        expectRefused(fixture.verdict("95% of compressions reached target depth."),
                      mentioning: "The share \"95%\" is not in the record.")
        expectRefused(fixture.verdict("Hands were on the chest 90 percent of the time."), mentioning: "90%")
    }

    @Test func refusesANumberWithTheWrongUnit() {
        // 120 is the rate. Written as centimetres it is not a depth, and the reason says so.
        expectRefused(fixture.verdict("Typical depth was 120 cm.", cites: fixture.compressionIDs),
                      mentioning: "\"120 cm\" is written as a depth, but the record has 120 only as a rate.")
        // 9 is a pause length in seconds, not a percentage and not a rate.
        expectRefused(fixture.verdict("Hands were off the chest 9% of the time."), mentioning: "only as a time")
        expectRefused(fixture.verdict("The rate was 9 per minute."), mentioning: "only as a time")
        // 5.3 is the depth in centimetres, not in millimetres.
        expectRefused(fixture.verdict("Typical depth was 5.3 mm."), mentioning: "5.3 mm")
        // A unit the checker does not know leaves a bare number, which must then be a count.
        expectRefused(fixture.verdict("The phone stood 9 m away."), mentioning: "\"9\" is written as a count")
    }

    @Test func refusesACountTiedToTheWrongThing() {
        // 3 is the number of pauses and 160 the number of compressions, not the other way round.
        expectRefused(fixture.verdict("3 compressions were recorded."), mentioning: "3 compressions")
        expectRefused(fixture.verdict("There were 160 long pauses."), mentioning: "160 pauses")
        expectRefused(fixture.verdict("There were no pauses."), mentioning: "The count \"no pauses\"")
        expectRefused(fixture.verdict("No compressions were recorded."), mentioning: "No compressions")
        expectRefused(fixture.verdict("Both pauses were short."), mentioning: "Both pauses")
        expectRefused(fixture.verdict("A single pause was recorded."), mentioning: "single pauses")
        // The same words with nothing counted after them are ordinary words.
        expectAccepted(fixture.verdict("No depth was recorded for both early runs."))
    }

    @Test func refusesTimesThatAreNotInTheRecord() {
        expectRefused(fixture.verdict("The longest pause lasted 12 seconds.", cites: fixture.pauseIDs),
                      mentioning: "The time \"12 s\" is not in the record.")
        expectRefused(fixture.verdict("The session ran for 2 min 40 s."), mentioning: "2 min 40 s")
        expectRefused(fixture.verdict("The session ran for 3 minutes."), mentioning: "3 min")
        expectRefused(fixture.verdict("CPR started at 14:07."),
                      mentioning: "The clock time \"14:07\" is not the session start time.")
        expectRefused(fixture.verdict("CPR started at 2:02."), mentioning: "2:02")
        expectRefused(fixture.verdict("CPR started at 2:02 am."), mentioning: "2:02")
        expectRefused(fixture.verdict("The session started at 14:02:11."), mentioning: "14:02:11")
    }

    @Test func refusesADepthMeasuredWhileDepthWasNotTrusted() {
        // The cited compression reads 70 mm, but it was measured without a depth lock.
        let verdict = fixture.verdict("That compression was 70 mm deep.", cites: [fixture.untrustedCompressionID])
        expectRefused(verdict, mentioning: "70 mm")
    }

    @Test(arguments: [
        ("There were twenty pauses.", "twenty"),
        ("Half of the compressions reached target depth.", "Half"),
        ("There were ½ as many pauses.", "½"),
        ("There were ３ pauses.", "３"),
        ("There were ٣ pauses.", "٣"),
        ("A couple of pauses were recorded.", "couple"),
        ("The rate doubled after the long pause.", "doubled"),
        ("III pauses were recorded.", "III"),
        ("3/4 of compressions reached target depth.", "3/4"),
    ])
    func refusesNumbersItCannotRead(text: String, written: String) {
        expectRefused(fixture.verdict(text), mentioning: "\"\(written)\", which cannot be checked")
    }

    @Test func aSpelledNumberIsCheckedLikeTheSameDigits() {
        expectRefused(fixture.verdict("There were four pauses.", cites: fixture.pauseIDs), mentioning: "four pauses")
        expectRefused(fixture.verdict("A pause lasted six seconds.", cites: fixture.pauseIDs), mentioning: "six s")
        expectRefused(fixture.verdict("The rescuer paused twice.", cites: fixture.pauseIDs), mentioning: "twice")
        expectAccepted(fixture.verdict("The rescuer paused thrice.", cites: fixture.pauseIDs))
    }

    // MARK: Cites

    @Test func refusesACiteThatDoesNotExist() {
        let verdict = fixture.verdict("160 compressions were recorded.", cites: [fixture.compressionIDs[0], 9_999])
        expectRefused(verdict, mentioning: "It cites entry 9999, which is not in the log.")
        expectRefused(fixture.verdict("160 compressions were recorded.", cites: [0]), mentioning: "entry 0")
    }

    @Test func refusesASentenceWithNoCites() {
        expectRefused(fixture.verdict("160 compressions were recorded.", cites: []),
                      mentioning: "It cites no log entries.")
    }

    // MARK: Banned ideas

    @Test func theBannedListIsTheAgreedOne() {
        #expect(BannedIdeas.all.map { $0.stems.joined(separator: " ") } == [
            "diagnos", "surviv", "prognos", "cause of", "heart attack", "cardiac arrest was", "dead", "death",
            "died", "alive", "pulse", "breathing normally", "drug", "dose", "mg", "medicat", "recover", "saved",
            "clinically", "accurate", "validated", "should have", "failed to", "blame",
        ])
    }

    @Test(arguments: [
        ("The rescuer may need a diagnosis.", "diagnosis", BannedTopic.diagnosis),
        ("The patient survived the session.", "survived", .outcome),
        ("The prognosis looks steady.", "prognosis", .outcome),
        ("Tiredness was the cause of the long pause.", "cause of", .cause),
        ("This looked like a heart attack.", "heart attack", .cause),
        ("The cardiac arrest was sudden.", "cardiac arrest was", .cause),
        ("The patient was dead on arrival.", "dead", .outcome),
        ("Compressions continued until death.", "death", .outcome),
        ("The patient died during the pause.", "died", .outcome),
        ("The patient is alive.", "alive", .outcome),
        ("A pulse returned after the pause.", "pulse", .signsOfLife),
        ("The patient was breathing normally afterwards.", "breathing normally", .signsOfLife),
        ("Drugs were given during the pause.", "drugs", .medicines),
        ("A dose was given during the pause.", "dose", .medicines),
        ("The amount in mg was not noted.", "mg", .medicines),
        ("Medication was given during the pause.", "medication", .medicines),
        ("The patient recovered after the session.", "recovered", .outcome),
        ("The rescuer saved the patient.", "saved", .outcome),
        ("Depth was clinically adequate.", "clinically", .accuracy),
        ("The depth readings were accurate.", "accurate", .accuracy),
        ("This is a validated measurement.", "validated", .accuracy),
        ("The rescuer should have pushed harder.", "should have", .blame),
        ("The rescuer failed to keep the rhythm.", "failed to", .blame),
        ("The rescuer is to blame for the pause.", "blame", .blame),
    ])
    func refusesEveryBannedIdea(text: String, found: String, topic: BannedTopic) {
        let verdict = fixture.verdict(text)
        expectRefused(verdict, mentioning: "It uses \"\(found)\"")
        expectRefused(verdict, mentioning: "the record says nothing about \(topic.rawValue).")
    }

    @Test(arguments: [
        ("The patient SURVIVED the session.", "survived"),
        ("The depth readings were inaccurate.", "inaccurate"),
        ("The measurement is unvalidated.", "unvalidated"),
        ("The condition was misdiagnosed.", "misdiagnosed"),
        ("This looked like an overdose.", "overdose"),
        ("This looked like a heart-attack.", "heart attack"),
        ("The injuries were non-survivable.", "survivable"),
        ("The patient was déad on arrival.", "dead"),
        ("Give 1 mg now.", "mg"),
        ("Give 1mg now.", "mg"),
    ])
    func refusesBannedIdeasInDisguise(text: String, found: String) {
        expectRefused(fixture.verdict(text), mentioning: "It uses \"\(found)\"")
    }

    @Test(arguments: [
        "The rhythm steadied after the long pause.",
        "The pause came because of a change of rescuer.",
        "Depth was indeed steady.",
        "Breathing was not recorded.",
        "Medicines were not recorded.",
        "The rescuer kept to the beat.",
    ])
    func harmlessWordsThatOnlyLookBannedAreAccepted(text: String) {
        expectAccepted(fixture.verdict(text))
    }

    // MARK: Shape and voice

    @Test func refusesTwoSentencesInOne() {
        let verdict = fixture.verdict("160 compressions were recorded. The rate was 120 per minute.",
                                      cites: fixture.compressionIDs)
        expectRefused(verdict, mentioning: "It is more than one sentence.")
        expectRefused(fixture.verdict("Was it steady? The rate was 120 per minute."), mentioning: "more than one")
        expectRefused(fixture.verdict("The rate was 120 per min. and steady."), mentioning: "more than one")
    }

    @Test func refusesMoreThanThirtyWords() {
        let thirty = Array(repeating: "steady", count: 30).joined(separator: " ") + "."
        let thirtyOne = Array(repeating: "steady", count: 31).joined(separator: " ") + "."
        expectAccepted(fixture.verdict(thirty))
        expectRefused(fixture.verdict(thirtyOne), mentioning: "It has 31 words, and the limit is 30.")
    }

    @Test func refusesLineBreaks() {
        expectRefused(fixture.verdict("160 compressions\nwere recorded."), mentioning: "It contains a line break.")
        expectRefused(fixture.verdict("160 compressions were recorded.\r\n"), mentioning: "line break")
    }

    @Test(arguments: [
        ("We recorded 160 compressions.", "first person (\"we\")"),
        ("I counted 160 compressions.", "first person (\"i\")"),
        ("I'm sure there were 3 pauses.", "first person (\"i\")"),
        ("Our record shows 160 compressions.", "first person (\"our\")"),
        ("The record shows us 160 compressions.", "first person (\"us\")"),
        ("As an AI, the record shows 160 compressions.", "the model itself (\"ai\")"),
        ("As a language model the record shows 3 pauses.", "the model itself (\"language model\")"),
    ])
    func refusesFirstPersonAndModelSelfReference(text: String, reason: String) {
        expectRefused(fixture.verdict(text), mentioning: reason)
    }

    @Test func refusesTextThatHidesFromTheWordChecks() {
        expectRefused(fixture.verdict("The patient was dea\u{200B}d on arrival."),
                      mentioning: "hidden or control characters")
        expectRefused(fixture.verdict("The patient\twas steady."), mentioning: "hidden or control characters")
        expectRefused(fixture.verdict("The patient was d3ad on arrival."), mentioning: "mixes digits into a word")
        expectRefused(fixture.verdict("The patient is aliv3."), mentioning: "mixes digits into a word")
        // The "е" and "а" here are Cyrillic letters that look like Latin ones.
        expectRefused(fixture.verdict("The patient was d\u{0435}\u{0430}d on arrival."),
                      mentioning: "letters outside the Latin alphabet")
    }

    @Test func refusesEmptyAndWordlessText() {
        expectRefused(fixture.verdict(""), mentioning: "It is empty.")
        expectRefused(fixture.verdict("   \n "), mentioning: "It is empty.")
        expectRefused(fixture.verdict("..."), mentioning: "It has no words.")
    }

    // MARK: How many

    @Test func refusesTheFourthSentenceWhenThreeAreAllowed() {
        let sentence = ScribeSentence(text: "160 compressions were recorded.", cites: fixture.compressionIDs)
        let verdicts = fixture.verify(Array(repeating: sentence, count: 5))

        #expect(verdicts.map(\.accepted) == [true, true, true, false, false])
        expectRefused(verdicts[3], mentioning: "Only 3 sentences are kept, and this is sentence 4.")
        expectRefused(verdicts[4], mentioning: "Only 3 sentences are kept, and this is sentence 5.")

        // The limit is three when the caller does not name one.
        let byDefault = ScribeVerifier.verify(Array(repeating: sentence, count: 4), log: fixture.log,
                                              stats: fixture.stats)
        #expect(byDefault.map(\.accepted) == [true, true, true, false])
    }

    @Test func theSentenceLimitCanBeChosen() {
        let sentence = ScribeSentence(text: "There were 3 pauses.", cites: fixture.pauseIDs)
        #expect(fixture.verify(Array(repeating: sentence, count: 3), maxSentences: 1).map(\.accepted)
            == [true, false, false])
        #expect(fixture.verify([sentence], maxSentences: 0).map(\.accepted) == [false])
    }

    @Test func aRefusedSentenceStillUsesUpItsPlace() {
        let good = ScribeSentence(text: "There were 3 pauses.", cites: fixture.pauseIDs)
        let bad = ScribeSentence(text: "There were 4 pauses.", cites: fixture.pauseIDs)
        #expect(fixture.verify([bad, bad, bad, good]).map(\.accepted) == [false, false, false, false])
    }

    @Test func everyReasonIsOnePlainSentence() {
        let texts = ["", "170 compressions were recorded.", "Typical depth was 120 cm.", "The patient survived.",
                     "We saw 3 pauses.", "A. B.", "CPR started at 14:07.", "There were twenty pauses."]
        let verdicts = fixture.verify(texts.map { ScribeSentence(text: $0, cites: [1]) }, maxSentences: texts.count)
        for verdict in verdicts {
            let reason = verdict.reason ?? ""
            #expect(!verdict.accepted)
            #expect(reason.hasSuffix("."), "\(reason)")
            #expect(!reason.contains("\n"), "\(reason)")
            #expect(reason.dropLast().contains(". ") == false, "\(reason)")
        }
    }
}
