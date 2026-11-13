import Foundation
@testable import HealthAISim
import RescueCore
import SwiftUI
import Testing

/// The deck's words: the step counter, which line leads, what lights up, and the guide cards.
@MainActor
@Suite struct StepProgressTests {
    private func begun(_ bundle: ProtocolBundle? = nil) throws -> Fixture {
        let fixture = try Fixture(bundle: try bundle ?? mergedBundle())
        fixture.coordinator.beginRescue()
        return fixture
    }

    private func progress(_ fixture: Fixture) -> String? {
        fixture.coordinator.stepProgress?.text
    }

    @Test func theSetupChainCountsToThree() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.perform(.unsure)
        #expect(coordinator.state.stateID == "call_911")
        #expect(progress(fixture) == "Step 1 of 3")
        coordinator.perform(.done)
        #expect(progress(fixture) == "Step 2 of 3")
        coordinator.perform(.done)
        #expect(coordinator.state.stateID == "place_hands")
        #expect(progress(fixture) == "Step 3 of 3")
    }

    /// A flow branches, so only how far someone has come is honest.
    @Test func aFlowCountsWithoutATotal() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.perform(.yes)
        coordinator.perform(.triageChest)
        #expect(progress(fixture) == "Step 1")
        coordinator.perform(.done)
        #expect(coordinator.state.stateID == "chest_aspirin_check")
        #expect(progress(fixture) == "Step 2")
        coordinator.perform(.no)
        #expect(coordinator.state.stateID == "chest_aspirin")
        #expect(progress(fixture) == "Step 3")
        coordinator.perform(.done)
        #expect(coordinator.state.stateID == "chest_wait")
        #expect(progress(fixture) == "Step 4")
        coordinator.perform(.scan)
        #expect(progress(fixture) == "Step 5")
        coordinator.perform(.done)
        #expect(coordinator.state.stateID == "chest_wait")
        #expect(progress(fixture) == "Step 4", "a step come back to keeps its number")
    }

    @Test func theLimbFlowCountsItsSteps() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.perform(.yes)
        coordinator.perform(.triageLimb)
        #expect(progress(fixture) == "Step 1")
        coordinator.perform(.done)
        coordinator.perform(.no)
        #expect(coordinator.state.stateID == "limb_splint")
        #expect(progress(fixture) == "Step 3")
        coordinator.perform(.done)
        #expect(progress(fixture) == "Step 4")
    }

    @Test func goingBackToTriageStartsTheCountAgain() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.perform(.yes)
        coordinator.perform(.triageChest)
        coordinator.perform(.done)
        #expect(progress(fixture) == "Step 2")
        coordinator.perform(.notThis)
        #expect(coordinator.state.stateID == "triage")
        #expect(progress(fixture) == nil)
        coordinator.perform(.triageLimb)
        #expect(progress(fixture) == "Step 1")
    }

    /// No sequence, no number: triage, cards, CPR and the questions before it.
    @Test(arguments: ["intake_responsive", "triage", "general_talk", "compressions", "resource_scan", "responsive_patient", "handoff"])
    func nothingElseIsNumbered(id: String) throws {
        let fixture = try begun()
        if fixture.coordinator.state.stateID != id { fixture.coordinator.force(stateID: id) }
        #expect(fixture.coordinator.state.stateID == id)
        #expect(fixture.coordinator.stepProgress == nil)
    }

    // MARK: - Which line leads

    @Test func aPossibleLineIsOnlyOneSentenceThatNamesIt() {
        #expect(AppCoordinator.isPossibleLine("Possible heart attack."))
        #expect(AppCoordinator.isPossibleLine(" Possible broken bone. "))
        #expect(!AppCoordinator.isPossibleLine("Possible broken bone. Keep it as found."), "it goes on to say what to do")
        #expect(!AppCoordinator.isPossibleLine("This may be a heart attack. Treat it as an emergency."))
        #expect(!AppCoordinator.isPossibleLine("Possible"))
    }

    /// Whatever the wording, the deck leads with one of the step's own lines, and never with a line
    /// that only names the condition while there's one that says what to do.
    @Test func theDeckLeadsWithTheStepsOwnLines() throws {
        let bundle = try mergedBundle()
        for state in bundle.definition.states where !state.entryPhrases.isEmpty {
            let fixture = try begun(bundle)
            if fixture.coordinator.state.stateID != state.id { fixture.coordinator.force(stateID: state.id) }
            guard fixture.coordinator.state.stateID == state.id else { continue }
            let lines = state.entryPhrases.compactMap(bundle.text(forPhrase:))
            let command = fixture.coordinator.deckCommand
            #expect(lines.contains(command), "\(state.id)")
            if lines.contains(where: { !AppCoordinator.isPossibleLine($0) }) {
                #expect(!AppCoordinator.isPossibleLine(command), "\(state.id)")
            }
            #expect(fixture.coordinator.deckDetail?.contains(command) != true, "\(state.id) says it twice")
        }
    }

    /// With the reworded flow, chest_call starts "Possible heart attack." The why row says that with
    /// "Not a diagnosis." after it, so the deck leads with the call, and `instruction` stays as pinned.
    @Test func aPossibleLineGivesWayToTheCommand() throws {
        var bundle = try mergedBundle()
        let index = try #require(bundle.phrases.phrases.firstIndex { $0.id == "chest_possible" })
        bundle.phrases.phrases[index].text = "Possible heart attack."
        let fixture = try begun(bundle)
        let coordinator = fixture.coordinator
        coordinator.perform(.yes)
        coordinator.perform(.triageChest)
        #expect(coordinator.state.stateID == "chest_call")
        #expect(coordinator.instruction == "Possible heart attack.")
        #expect(coordinator.deckCommand == bundle.text(forPhrase: "call_911"))
        #expect(coordinator.deckDetail == bundle.text(forPhrase: "chest_sit"))
        #expect(coordinator.flowExplanation?.headline == "Possible heart attack. Not a diagnosis.")
    }

    // MARK: - What lights up

    @Test func emphasisNeverChangesAWord() throws {
        let bundle = try mergedBundle()
        let targets: [OverlayTarget?] = [nil] + OverlayTarget.allCases.map(Optional.some)
        for phrase in bundle.phrases.phrases {
            for target in targets {
                let terms = CommandEmphasis.terms(target: target, materials: RescueCore.Material.allCases)
                #expect(String(CommandEmphasis.attributed(phrase.text, terms: terms).characters) == phrase.text, "\(phrase.id)")
            }
        }
    }

    private func runs(_ text: AttributedString, colored color: Color) -> [String] {
        text.runs.filter { $0.foregroundColor == color }.map { String(text[$0.range].characters) }
    }

    @Test func theBodyPartTakesTheTargetColor() {
        let text = CommandEmphasis.attributed(
            "Heel of one hand on the center of the chest. Other hand on top.",
            terms: CommandEmphasis.terms(target: .chestCenter)
        )
        #expect(runs(text, colored: DS.Colors.target) == ["center of the chest"])
    }

    @Test func theThingToGrabTakesTheItemColor() {
        let text = CommandEmphasis.attributed("Bare the chest. Stick the pads where the pictures show.", terms: CommandEmphasis.terms(target: .padZones))
        #expect(runs(text, colored: DS.Colors.target) == ["chest"])
        #expect(runs(text, colored: DS.Colors.item) == ["pads"])
        let towel = CommandEmphasis.attributed("Pad under it: Towel, pillow.", terms: CommandEmphasis.terms(target: nil, materials: [.towel]))
        #expect(runs(towel, colored: DS.Colors.item) == ["Towel"], "case doesn't matter")
    }

    @Test func onlyWholeWordsAndOnlyTheFirst() {
        let terms = CommandEmphasis.Terms(body: ["arm"], item: [])
        #expect(runs(CommandEmphasis.attributed("The alarm sounds.", terms: terms), colored: DS.Colors.target).isEmpty)
        #expect(runs(CommandEmphasis.attributed("Arm first, then the arm again.", terms: terms), colored: DS.Colors.target) == ["Arm"])
        #expect(CommandEmphasis.attributed("Nothing here.", terms: CommandEmphasis.Terms()).runs.count == 1)
    }

    // MARK: - Guide cards

    /// A card's words are a line its own step says, so the card can't add advice or drift from it.
    @Test func everyGuideReadsItsOwnStepsPhrase() throws {
        let bundle = try mergedBundle()
        let guided = bundle.definition.states.filter { $0.guide != nil }
        #expect(!guided.isEmpty)
        for state in guided {
            let guide = try #require(state.guide)
            let id = GuideWords.phraseID(for: guide)
            #expect(state.entryPhrases.contains(id), "\(state.id)")
            let text = try #require(bundle.text(forPhrase: id))
            let words = GuideWords.split(text)
            #expect(words.title + (words.detail.map { " \($0)" } ?? "") == text.trimmingCharacters(in: .whitespaces))
        }
    }

    @Test func aGuideSplitsAtItsFirstSentence() {
        let words = GuideWords.split("Don't straighten it. Pad under it: towel, pillow.")
        #expect(words.title == "Don't straighten it.")
        #expect(words.detail == "Pad under it: towel, pillow.")
        let one = GuideWords.split("Support it as it lies with a towel, pillow, or rolled clothes.")
        #expect(one.title == "Support it as it lies with a towel, pillow, or rolled clothes.")
        #expect(one.detail == nil)
    }
}
