import PlumbContracts
import Testing
@testable import PlumbCoach

@Suite("Wording")
struct WordingTests {
    @Test("Every cue has spoken words and command words, and the command is upper case",
          arguments: Cue.allCases)
    func everyCueHasWords(cue: Cue) {
        #expect(!cue.spokenText.isEmpty)
        #expect(!cue.commandText.isEmpty)
        #expect(cue.commandText == cue.commandText.uppercased())
        #expect(cue.commandText.contains { $0.isLetter })
    }

    @Test("Spoken words are sentence case: one capital at the start and nowhere else", arguments: Cue.allCases)
    func spokenIsSentenceCase(cue: Cue) {
        let text = cue.spokenText
        #expect(text.first?.isUppercase == true)
        #expect(text.dropFirst() == text.dropFirst().lowercased())
    }

    @Test("The words are the defibrillator-style prompts, exactly")
    func exactWords() {
        #expect(Cue.pushNow.spokenText == "Push now")
        #expect(Cue.pushHarder.spokenText == "Push harder")
        #expect(Cue.faster.spokenText == "Faster")
        #expect(Cue.slower.spokenText == "Slower")
        #expect(Cue.good.spokenText == "Good compressions")

        #expect(Cue.pushNow.commandText == "PUSH NOW")
        #expect(Cue.pushHarder.commandText == "PUSH HARDER")
        #expect(Cue.faster.commandText == "FASTER")
        #expect(Cue.slower.commandText == "SLOWER")
        #expect(Cue.good.commandText == "GOOD")
    }
}
