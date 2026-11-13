import Foundation
@testable import HealthAISim
import RescueCore
import Testing

private let flowSteps = [
    "chest_call", "chest_aspirin_check", "chest_aspirin", "chest_wait", "chest_scan",
    "limb_start", "limb_flags", "limb_splint", "limb_wait", "limb_danger",
]
private let awakeStates = ["triage", "general_talk", "choking_talk"] + flowSteps

/// What the awake screens offer, with no key, no model, and no network. The drawing itself is checked
/// in the Simulator.
@MainActor
@Suite struct FlowScreenTests {
    private func forced(_ id: String, bundle: ProtocolBundle? = nil) throws -> Fixture {
        let fixture = try Fixture(bundle: try bundle ?? mergedBundle())
        fixture.coordinator.beginRescue()
        fixture.coordinator.force(stateID: id)
        #expect(fixture.coordinator.state.stateID == id)
        return fixture
    }

    private func moduleSource(_ id: String) -> ModuleSource {
        let url = Bundle.main.url(forResource: id, withExtension: "json", subdirectory: "clinical/modules")
        return ModuleSource(id: id, data: url.flatMap { try? Data(contentsOf: $0) })
    }

    private func merged(dropping dropped: Set<String>) throws -> ProtocolBundle {
        let modules = ScenarioModule.manifest.map { id in
            dropped.contains(id) ? ModuleSource(id: id, data: nil) : moduleSource(id)
        }
        let pack = Bundle.main.url(forResource: KnowledgePack.id, withExtension: "json", subdirectory: "clinical")
            .flatMap { try? Data(contentsOf: $0) }
        return try shippedBundle().merging(modules: modules, pack: pack)
    }

    private func role(_ fixture: Fixture, _ action: HumanAction) -> RescueControl.Role? {
        fixture.coordinator.controls.first { $0.action == action }?.role
    }

    // MARK: - The triage group

    @Test func triageOffersTheFlowsInReadingOrder() throws {
        let fixture = try forced("triage")
        let group = RescueControls.triageGroup(fixture.coordinator.controls)
        #expect(group.map(\.action) == [.triageChest, .triageLimb, .triageOther])
        #expect(group.allSatisfy { $0.role == .triage })
        #expect(fixture.coordinator.controls.filter { $0.role == .triage }.count == 3, "none left out of the group")
    }

    @Test(arguments: [
        ("possible_heart_attack.v1", [HumanAction.triageLimb, .triageOther]),
        ("possible_broken_bone.v1", [HumanAction.triageChest, .triageOther]),
    ])
    func aDroppedFlowTakesItsButtonWithIt(dropped: String, left: [HumanAction]) throws {
        let bundle = try merged(dropping: [dropped])
        #expect(bundle.moduleFailures.map(\.id) == [dropped])
        let fixture = try forced("triage", bundle: bundle)
        #expect(RescueControls.triageGroup(fixture.coordinator.controls).map(\.action) == left)
    }

    @Test func noFlowsLeaveTheOtherButtonAndTheCollapse() throws {
        let bundle = try merged(dropping: ["possible_heart_attack.v1", "possible_broken_bone.v1"])
        let fixture = try forced("triage", bundle: bundle)
        #expect(RescueControls.triageGroup(fixture.coordinator.controls).map(\.action) == [.triageOther])
        #expect(role(fixture, .startCpr) == .primary)
        #expect(role(fixture, .patientUnresponsive) == .collapse)
    }

    @Test func noTriageMeansYesGoesToTheStaticCardWithNoNewButtons() throws {
        let bundle = try merged(dropping: ["triage.v1"])
        let fixture = try Fixture(bundle: bundle)
        fixture.coordinator.beginRescue()
        fixture.coordinator.perform(.yes)
        #expect(fixture.coordinator.state.stateID == "responsive_patient")
        #expect(fixture.coordinator.controls.map(\.action) == [.patientUnresponsive, .startCpr, .emsArrived])
        #expect(fixture.coordinator.flowExplanation == nil)
    }

    // MARK: - What every awake state keeps

    @Test(arguments: awakeStates)
    func everyAwakeStateKeepsTheWayOutAndTheHolds(id: String) throws {
        let fixture = try forced(id)
        #expect(role(fixture, .startCpr) == .primary)
        #expect(role(fixture, .patientUnresponsive) == .collapse)
        #expect(role(fixture, .notAdult) == .holdStep)
        #expect(role(fixture, .emsArrived) == .holdStep, "a mis-tap here can't be undone on screen")
    }

    /// A control left out of the panel's layout would simply not be on screen.
    @Test(arguments: awakeStates)
    func everyAwakeControlHasOnePlaceInThePanel(id: String) throws {
        let controls = try forced(id).coordinator.controls
        let layout = RescueControls.awakeLayout(controls)
        #expect(layout.all.count == controls.count, "\(id)")
        #expect(Set(layout.all.map(\.action)) == Set(controls.map(\.action)), "\(id)")
        #expect(layout.primary.map(\.action) == [.startCpr], "\(id)")
        #expect(layout.collapse.map(\.action) == [.patientUnresponsive], "\(id)")
        #expect(layout.emsArrived.map(\.action) == [.emsArrived], "\(id)")
    }

    /// Offline there's no AI to hear it, so choking has to be a tap away.
    @Test func somethingElseOffersChoking() throws {
        let fixture = try forced("general_talk")
        #expect(RescueControls.triageGroup(fixture.coordinator.controls).map(\.action) == [.triageChoking])
        fixture.clock.advance(1)
        fixture.coordinator.performStep(.triageChoking)
        #expect(fixture.coordinator.state.stateID == "choking_talk")
        #expect(fixture.coordinator.instruction == fixture.coordinator.engine.bundle.text(forPhrase: "choking_steps"))
        fixture.run(seconds: 9)
        #expect(fixture.coordinator.instruction == fixture.coordinator.engine.bundle.text(forPhrase: "choking_steps"), "the steps outlast a passing prompt")
    }

    @Test(arguments: awakeStates)
    func startCPRFromAnAwakeStateIsOneTapWithNoNetwork(id: String) throws {
        let fixture = try forced(id)
        fixture.coordinator.perform(.startCpr)
        #expect(fixture.coordinator.state.stateID == "compressions")
        #expect(fixture.audio.metronome.last == true)
        #expect(fixture.coordinator.linkLabel == "Offline protocol")
        #expect(fixture.mock.requests.isEmpty)
    }

    /// The child and adult holds pair up off triage, and the panel lays out any pair.
    @Test(arguments: ["general_talk", "choking_talk"] + flowSteps)
    func notThisIsHeldAndGoesBackToTriage(id: String) throws {
        let fixture = try forced(id)
        #expect(role(fixture, .notThis) == .holdStep)
        fixture.coordinator.perform(.notThis)
        #expect(fixture.coordinator.state.stateID == "triage")
        #expect(fixture.coordinator.flowExplanation == nil)
    }

    /// The edge stays in the graph, but from here it would only ask the same question again.
    @Test func triageHasNoButtonForGoingBackToItself() throws {
        let fixture = try forced("triage")
        #expect(fixture.coordinator.engine.definition(of: "triage")?.transition(on: "human.not_this")?.to == "triage")
        #expect(role(fixture, .notThis) == nil)
    }

    // MARK: - The static card

    @Test func theStaticCardOffersTriageAsAPlainStep() throws {
        let fixture = try forced("responsive_patient")
        #expect(role(fixture, .triageOpen) == .step)
        #expect(role(fixture, .patientUnresponsive) == .step, "the card isn't an awake state")
        fixture.coordinator.perform(.triageOpen)
        #expect(fixture.coordinator.state.stateID == "triage")
    }

    /// The engine sends this tap straight back to the card, so the screen doesn't offer it.
    @Test func afterCPRTheCardDoesNotOfferTriage() throws {
        let fixture = try Fixture(bundle: try mergedBundle())
        fixture.coordinator.beginRescue()
        fixture.coordinator.perform(.startCpr)
        #expect(fixture.coordinator.state.stateID == "compressions")
        fixture.coordinator.perform(.patientMoving)
        fixture.coordinator.perform(.patientAwake)
        #expect(fixture.coordinator.state.stateID == "responsive_patient")
        #expect(fixture.coordinator.state.cprStarted)
        #expect(role(fixture, .triageOpen) == nil)
        #expect(role(fixture, .startCpr) == .primary)
    }

    // MARK: - The arrest screen stays as it was

    @Test func noArrestStateChangesItsButtons() throws {
        let core = try shippedBundle()
        let merged = try mergedBundle()
        let coreEngine = ProtocolEngine(bundle: core)
        let mergedEngine = ProtocolEngine(bundle: merged)
        for state in core.definition.states {
            let before = RescueControls.derive(definition: state, engine: coreEngine, metronomeOn: false)
            #expect(!before.contains { $0.role == .triage || $0.role == .collapse }, "\(state.id)")

            let after = try #require(mergedEngine.definition(of: state.id))
            for locked in [false, true] {
                let controls = RescueControls.derive(definition: after, engine: mergedEngine, metronomeOn: false, awakeLocked: locked)
                    .filter { $0.action != .triageOpen }
                #expect(controls == before, "\(state.id), locked \(locked)")
            }
        }
    }

    /// From inside a flow, or the why panel would have nothing to be left over from.
    @Test func noArrestStateHasAWhyPanelOrGuideOrStepDetail() throws {
        let core = try shippedBundle().definition.states.map(\.id)
        let fixture = try Fixture(bundle: try mergedBundle())
        fixture.coordinator.beginRescue()
        fixture.coordinator.perform(.yes)
        fixture.coordinator.perform(.triageChest)
        #expect(fixture.coordinator.flowExplanation != nil)
        for id in core {
            let state = try #require(fixture.coordinator.engine.definition(of: id))
            fixture.coordinator.force(stateID: state.id)
            #expect(fixture.coordinator.flowExplanation == nil, "\(state.id)")
            #expect(fixture.coordinator.definition?.guide == nil, "\(state.id)")
            #expect(fixture.coordinator.stepDetail == nil, "\(state.id)")
        }
    }

    // MARK: - What the screen says

    @Test func theGuideCardsAreOnTheirOwnStepsOnly() throws {
        let guides = try mergedBundle().definition.states.compactMap { state in
            state.guide.map { (state.id, $0) }
        }
        #expect(guides.count == 2)
        #expect(guides.first { $0.0 == "chest_call" }?.1 == .sitRest)
        #expect(guides.first { $0.0 == "limb_splint" }?.1 == .supportLimb)
    }

    @Test(arguments: awakeStates)
    func everyAwakeStepHasWordsOnScreen(id: String) throws {
        let fixture = try forced(id)
        #expect(!fixture.coordinator.instruction.isEmpty)
    }

    /// Past the 8 s a passing prompt lasts, and on a step with a longer timer it has to still be there.
    @Test func aStepsOwnLinesLastAsLongAsTheStep() throws {
        let fixture = try Fixture(bundle: try mergedBundle())
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.yes)
        coordinator.perform(.triageChest)
        let lines = try #require(coordinator.stepDetail)
        fixture.run(seconds: 9.5)
        #expect(coordinator.state.stateID == "chest_call")
        #expect(coordinator.stepDetail == lines)

        coordinator.perform(.done)
        #expect(coordinator.stepDetail == nil, "the last step's lines aren't left over on the next")
        #expect(coordinator.prompt == nil)
    }

    @Test func aPassingLineDoesNotFollowACollapseOntoTheArrestPath() throws {
        let fixture = try Fixture(bundle: try mergedBundle())
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.yes)
        coordinator.perform(.triageChest)
        coordinator.perform(.done)
        coordinator.perform(.yes)
        #expect(coordinator.prompt?.text == coordinator.engine.bundle.text(forPhrase: "aspirin_skip"))

        coordinator.perform(.patientUnresponsive)
        #expect(coordinator.state.stateID == "intake_breathing")
        #expect(coordinator.prompt == nil)
    }

    /// Start CPR's own lines still come through, since they're said on the way in.
    @Test func startCPRFromAFlowStillShowsWhatItSays() throws {
        let fixture = try forced("chest_wait")
        fixture.coordinator.perform(.startCpr)
        #expect(fixture.coordinator.prompt?.text.contains(fixture.coordinator.engine.bundle.text(forPhrase: "hands_center") ?? "?") == true)
    }

    @Test func theWhyPanelFollowsTheFlowFromTheLog() throws {
        let fixture = try Fixture(bundle: try mergedBundle())
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        #expect(coordinator.flowExplanation == nil)
        coordinator.perform(.yes)
        #expect(coordinator.flowExplanation == nil, "triage has no flow yet")

        coordinator.perform(.triageLimb)
        let why = try #require(coordinator.flowExplanation)
        #expect(why.headline == "Possible broken bone. Not a diagnosis.")
        #expect(why.chooser == .person)

        coordinator.perform(.patientUnresponsive)
        #expect(coordinator.flowExplanation == nil, "a collapse leaves the flow")
    }

    /// The step's own buttons wait this out. The way out never does, and it lives elsewhere in the panel.
    @Test func aNewStepSettlesBrieflyBeforeItsButtonsCount() throws {
        let fixture = try forced("triage")
        fixture.coordinator.performStep(.triageChest)
        #expect(fixture.coordinator.state.stateID == "triage", "the tap arrived too soon to count")
        fixture.clock.advance(0.5)
        fixture.coordinator.performStep(.triageChest)
        #expect(fixture.coordinator.state.stateID == "triage")
        fixture.clock.advance(0.2)
        fixture.coordinator.performStep(.triageChest)
        #expect(fixture.coordinator.state.stateID == "chest_call")

        fixture.coordinator.performStep(.done)
        #expect(fixture.coordinator.state.stateID == "chest_call", "a double tap doesn't reach the aspirin question")
    }

    // MARK: - The chip

    @Test func theCallChipNeedsALinkACallAndAnAwakeState() async throws {
        let fixture = try Fixture(live: true, bundle: try mergedBundle())
        try await fixture.beginAndConnect()
        let coordinator = fixture.coordinator
        coordinator.dispatch(.callChanged(active: true))
        #expect(!coordinator.aiPausedForCall, "the arrest screen stays as it was")

        coordinator.force(stateID: "triage")
        #expect(!coordinator.aiPausedForCall, "the session is swapping, so no AI is up to pause")
        try await waitUntil("the awake session connected") { fixture.awakeMock.requests.count == 1 }
        fixture.awakeMock.emit(.ready)
        try await waitUntil("the link came up") { coordinator.liveConnected }
        #expect(coordinator.aiPausedForCall)
        coordinator.dispatch(.callChanged(active: false))
        #expect(!coordinator.aiPausedForCall)
    }

    @Test func withNoLinkThereIsNoAIToPause() throws {
        let fixture = try forced("triage")
        fixture.coordinator.dispatch(.callChanged(active: true))
        #expect(!fixture.coordinator.aiPausedForCall)
    }
}
