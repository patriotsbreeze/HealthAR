import Foundation
import Testing
@testable import PlumbSignal

@Suite struct ChestWordingTests {
    private func reading(_ state: ChestReading.State, startPushing: Bool = false) -> ChestReading {
        ChestReading(t: 0, state: state, startPushing: startPushing, promptedAt: startPushing ? 0 : nil,
                     thresholdMM: 2, swingMM: nil, trace: .blank(.init()))
    }

    /// Every string the check can put on screen.
    private var everyString: [String] {
        let states: [ChestReading.State] = [.unmeasured, .settling, .movementSeen, .noMovementSeen(forSeconds: 12)]
        let readings = states.flatMap { [reading($0), reading($0, startPushing: true)] }
        return readings.flatMap {
            [$0.statusText, $0.commandText, $0.contextText, $0.state.noteBeforeCPR,
             $0.promptNoteBeforeCPR(stillForS: 10)].compactMap { $0 }
        }
    }

    @Test func theWordsAreExactly() {
        #expect(ChestReading.State.unmeasured.words == "Looking for the chest")
        #expect(ChestReading.State.settling.words == "Watching the chest")
        #expect(ChestReading.State.movementSeen.words == "Chest movement seen")
        #expect(ChestReading.State.noMovementSeen(forSeconds: 12).words == "No chest movement seen for 12\u{00A0}s")
        #expect(ChestReading.startPushingWords == "Start pushing")
        #expect(ChestReading.tapTheChestWords == "Tap the chest on the picture")
    }

    @Test func theRecordKeepsOnlyWhatTheCheckDecided() {
        #expect(ChestReading.State.noMovementSeen(forSeconds: 12.4).noteBeforeCPR
            == "No chest movement seen for 12\u{00A0}s before CPR.")
        #expect(ChestReading.State.movementSeen.noteBeforeCPR == "Chest movement seen before CPR.")
        #expect(ChestReading.State.unmeasured.noteBeforeCPR == nil)
        #expect(ChestReading.State.settling.noteBeforeCPR == nil)
    }

    /// The prompt is the reason pushing began, and stays once given whatever the chest does next, so
    /// the record keeps it on its own line rather than only what the check saw last.
    @Test func theRecordKeepsThePromptWhateverTheCheckSawLast() {
        #expect(reading(.movementSeen, startPushing: true).promptNoteBeforeCPR(stillForS: 10)
            == "Start pushing prompted after no chest movement seen for 10\u{00A0}s.")
        #expect(reading(.unmeasured, startPushing: true).promptNoteBeforeCPR(stillForS: 10) != nil)
        #expect(reading(.noMovementSeen(forSeconds: 14), startPushing: true).promptNoteBeforeCPR(stillForS: 10)
            == "Start pushing prompted after no chest movement seen for 10\u{00A0}s.")
        for state: ChestReading.State in [.unmeasured, .settling, .movementSeen, .noMovementSeen(forSeconds: 9)] {
            #expect(reading(state).promptNoteBeforeCPR(stillForS: 10) == nil)
        }
    }

    @Test func theCountIsWholeSecondsAndNeverRunsAhead() {
        #expect(ChestReading.State.noMovementSeen(forSeconds: 12.97).words.hasSuffix("for 12\u{00A0}s"))
        #expect(ChestReading.State.noMovementSeen(forSeconds: 10).words.hasSuffix("for 10\u{00A0}s"))
        #expect(ChestReading.State.noMovementSeen(forSeconds: 125.4).words.hasSuffix("for 125\u{00A0}s"))
    }

    @Test func nothingSaysAnythingAboutThePerson() {
        let banned = ["breath", "fine", "alive", "okay", "safe", "normal", "diagnos", "detect", "ai "]
        for string in everyString {
            let lower = string.lowercased() + " "
            for word in banned {
                #expect(!lower.contains(word), "\"\(string)\" contains \"\(word)\"")
            }
        }
    }

    @Test func theCommandAppearsOnlyOnceThePromptHasFired() {
        #expect(reading(.movementSeen).commandText == nil)
        #expect(reading(.noMovementSeen(forSeconds: 9.9)).commandText == nil)
        #expect(reading(.movementSeen, startPushing: true).commandText == "Start pushing")
    }

    @Test func theContextLineAsksForATapOrCarriesTheStatusUnderTheCommand() {
        #expect(reading(.unmeasured).contextText == "Tap the chest on the picture")
        #expect(reading(.unmeasured, startPushing: true).contextText == "Tap the chest on the picture")
        #expect(reading(.settling).contextText == nil)
        #expect(reading(.movementSeen).contextText == nil)
        #expect(reading(.movementSeen, startPushing: true).contextText == "Chest movement seen")
        #expect(reading(.noMovementSeen(forSeconds: 14), startPushing: true).contextText
            == "No chest movement seen for 14\u{00A0}s")
    }
}
