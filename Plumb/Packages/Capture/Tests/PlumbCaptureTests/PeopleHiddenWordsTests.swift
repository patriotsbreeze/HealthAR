import Testing
@testable import PlumbCapture

/// The sentence the session log keeps about what was hidden before a picture left the phone.
struct PeopleHiddenWordsTests {
    @Test func saysHowMuchWasFilledAndHowManyFaces() {
        #expect(PeopleHidden(filledFraction: 0.123, faceCount: 1).sentence
            == "People hidden before sending: 12% of the picture, 1 face.")
        #expect(PeopleHidden(filledFraction: 0.4, faceCount: 3).sentence
            == "People hidden before sending: 40% of the picture, 3 faces.")
        #expect(PeopleHidden(filledFraction: 0.05, faceCount: 0).sentence
            == "People hidden before sending: 5% of the picture, no faces.")
    }

    @Test func aSliverIsNeverRoundedAway() {
        #expect(PeopleHidden(filledFraction: 0.002, faceCount: 0).sentence
            == "People hidden before sending: under 1% of the picture, no faces.")
    }

    @Test func nothingFilledSaysNoOneWasFound() {
        #expect(PeopleHidden(filledFraction: 0, faceCount: 0).sentence
            == "People hidden before sending: no one found in the picture.")
    }
}
