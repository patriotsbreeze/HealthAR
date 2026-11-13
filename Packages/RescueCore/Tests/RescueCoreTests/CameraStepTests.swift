import Foundation
import Testing
@testable import RescueCore

private let limbSteps = ["limb_start", "limb_flags", "limb_splint", "limb_wait", "limb_danger"]

/// What the two flows' camera steps declare, and the AED line for someone awake, through the real engine.
@Suite struct CameraStepTests {
    private func engine() throws -> ProtocolEngine { ProtocolEngine(bundle: try loadMergedBundle()) }

    private func inScan() throws -> Session {
        var session = Session(engine: try engine())
        for action in [HumanAction.yes, .triageChest, .done, .yes, .scan] { session.human(action) }
        #expect(session.state.stateID == "chest_scan")
        return session
    }

    // MARK: - The AED line

    @Test func anAEDSpottedInAnAwakeScanGetsItsOwnLine() throws {
        var session = try inScan()
        session.model(.reportResources([.aed]))
        #expect(session.phrases == ["aed_found"])
        #expect(!session.allPhrases.contains("aed_spotted"), "Keep pushing is no line for someone awake")
        #expect(session.state.resources.contains(.aed))
    }

    @Test func theLineHoldsForTheFloorAndOnlyPlaysOnce() throws {
        var held = try inScan()
        held.modelFinding(.dispatcherSpeaking)
        held.model(.reportResources([.aed]))
        #expect(held.phrases.isEmpty, "the dispatcher has the floor")

        var twice = try inScan()
        twice.model(.reportResources([.aed]))
        twice.advance(1)
        twice.model(.reportResources([.aed]))
        #expect(twice.phrases.isEmpty)
    }

    /// It mentions the arrow, so it stays on the step that can have one.
    @Test func aStepThatDoesNotListTheLineStaysQuiet() throws {
        var session = Session(engine: try engine())
        for action in [HumanAction.yes, .triageChest, .done, .yes] { session.human(action) }
        #expect(session.state.stateID == "chest_wait")
        session.model(.reportResources([.aed]))
        #expect(session.phrases.isEmpty)
        #expect(session.state.resources.contains(.aed), "still on the record")
    }

    @Test(arguments: [HumanAction.startCpr])
    func theArrestPathKeepsItsLine(action: HumanAction) throws {
        for bundle in [try loadBundle(), try loadMergedBundle()] {
            var session = Session(engine: ProtocolEngine(bundle: bundle))
            session.human(action)
            session.human(.scan)
            session.model(.reportResources([.aed]))
            #expect(session.phrases == ["aed_spotted"])
        }
    }

    /// The line answers a report of an AED, so the model can't play it with no report, and isn't offered it.
    @Test func theLineTakesAReportAndNotASay() throws {
        var session = try inScan()
        #expect(session.engine.definition(of: "chest_scan")?.allowedSay.contains("aed_found") == true, "where the hint may play")
        let brief = session.engine.brief(for: session.state, definition: try #require(session.engine.definition(of: "chest_scan")), at: session.now)
        #expect(brief.allowedSay == ["assign_helper"])

        session.model(.say(phraseID: "aed_found"))
        #expect(session.phrases.isEmpty)
        #expect(session.entries(.proposalRejected).last?.detail.hasSuffix(SafetyGate.RejectReason.phraseNotAllowed.rawValue) == true)
        #expect(session.state.resources.isEmpty)

        session.model(.say(phraseID: "assign_helper"))
        #expect(session.phrases == ["assign_helper"], "the step's other line is still the model's")
    }

    @Test func theArrestPathStillLetsTheModelSayItsAEDLine() throws {
        for bundle in [try loadBundle(), try loadMergedBundle()] {
            var session = Session(engine: ProtocolEngine(bundle: bundle))
            session.human(.startCpr)
            session.model(.say(phraseID: "aed_spotted"))
            #expect(session.phrases == ["aed_spotted"])
        }
    }

    @Test func theOtherHintsAreUntouched() throws {
        var session = try inScan()
        session.model(.reportResources([.secondPerson]))
        #expect(session.phrases == ["assign_helper"])
    }

    @Test func aDroppedFlowTakesItsHintWithIt() throws {
        let clinical = repoRoot().appendingPathComponent("clinical")
        let modules = ["triage.v1", "possible_broken_bone.v1"].map { id in
            ModuleSource(id: id, data: try? Data(contentsOf: clinical.appendingPathComponent("modules/\(id).json")))
        }
        let bundle = try loadBundle().merging(modules: modules, pack: nil)
        #expect(bundle.awakeResourceHints == ["gloves": "limb_gloves"], "broken bone brings its own")
        #expect(bundle.text(forPhrase: "aed_found") == nil)

        var session = Session(engine: ProtocolEngine(bundle: bundle))
        session.human(.yes)
        session.model(.reportResources([.aed]))
        #expect(session.phrases.isEmpty)
    }

    /// The module's step can't claim a search it may not be running, or a find it may not have made. A
    /// report of an AED can be a mention, or a mistake.
    @Test func theScanLinesClaimNoSearchAndNoFind() throws {
        let bundle = try loadMergedBundle()
        let look = try #require(bundle.text(forPhrase: "aed_look")).lowercased()
        #expect(!look.contains("finding"))
        #expect(!look.contains("show me"))
        let found = try #require(bundle.text(forPhrase: "aed_found"))
        #expect(found.hasPrefix("If there's an AED"))
        #expect(!found.lowercased().contains("spotted") && !found.lowercased().contains("found"))
        #expect(found.contains("if it shows"), "a report can come with no arrow")
    }

    // MARK: - What the steps declare

    @Test func coreStillDecodesWithNoPin() throws {
        let core = try loadBundle()
        #expect(core.definition.states.allSatisfy { $0.overlay != .injurySite })
        #expect(OverlayTarget(rawValue: "injury_site") == .injurySite)
    }

    @Test func thePinIsOnTheLimbStepsAndNowhereElse() throws {
        let bundle = try loadMergedBundle()
        let declaring = bundle.definition.states.filter { $0.overlay == .injurySite }.map(\.id)
        #expect(Set(declaring) == Set(limbSteps))
    }

    /// A tap goes no further than the phone. A frozen frame may go to the locator to find the step's
    /// materials, and Live still sees nothing.
    @Test(arguments: limbSteps)
    func aLimbStepMayLocateButStreamsNoFrames(id: String) throws {
        let engine = try engine()
        let definition = try #require(engine.definition(of: id))
        #expect(!definition.frameUplink)
        #expect(definition.locateMaterials)

        var state = engine.start(at: 0).state
        state.stateID = id
        let policy = engine.policy(for: state, at: 0)
        #expect(!policy.frameUplink)
        #expect(policy.frameLocate)
        #expect(engine.materialsToLocate(for: state, at: 0) == [.towel, .pillow, .gloves], "the whole flow's, from its first step")
    }

    @Test func theScanStillOpensFramesAndStartsNoIdleRate() throws {
        let session = try inScan()
        let policy = session.engine.policy(for: session.state, at: session.now)
        #expect(policy.frameUplink)
        #expect(policy.frameBurstsOnly)
    }

    // MARK: - What carries over

    @Test func onlyAnAwakeScanCarriesAndOnlyCompressionsShows() throws {
        let engine = try engine()
        for definition in engine.bundle.definition.states {
            var state = engine.start(at: 0).state
            state.stateID = definition.id
            let policy = engine.policy(for: state, at: 0)
            #expect(policy.aedFindsCarry == definition.kind.isAwake, "\(definition.id)")
            #expect(policy.showsCarriedAED == (definition.id == "compressions"), "\(definition.id)")
        }
    }

    /// Once a person says the AED is here, the place it was seen is no use, on any way back to compressions.
    @Test(arguments: [[HumanAction.emsArrived, .resumeCpr], [.patientMoving, .startCpr]])
    func aedHereEndsTheCarriedArrow(back: [HumanAction]) throws {
        var session = try inScan()
        session.human(.startCpr)
        #expect(session.state.stateID == "compressions")
        #expect(session.engine.policy(for: session.state, at: session.now).showsCarriedAED)

        session.human(.aedHere)
        #expect(session.state.stateID == "aed_on")
        back.forEach { session.human($0) }
        #expect(session.state.stateID == "compressions")
        #expect(!session.engine.policy(for: session.state, at: session.now).showsCarriedAED)
    }

    /// Core's own file has no overlay here, which is why the policy has to say so.
    @Test func compressionsHasNoOverlayOfItsOwn() throws {
        #expect(try loadBundle().definition.states.first { $0.id == ScenarioModule.carriedAEDState }?.overlay == nil)
    }
}
