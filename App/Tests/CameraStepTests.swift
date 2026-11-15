import Foundation
@testable import HealthAISim
import RescueCore
import RescueVision
import Synchronization
import SwiftUI
import Testing
import UIKit

private let limbSteps = ["limb_start", "limb_flags", "limb_splint", "limb_wait", "limb_danger"]
private let otherTargets: [(String, OverlayTarget?)] = [
    ("chest_scan", .aedDevice), ("resource_scan", .aedDevice), ("place_hands", .chestCenter), ("pads", .padZones),
    ("choke_back_blows", .upperBack), ("choke_thrusts", .upperAbdomen),
    ("compressions", nil), ("triage", nil), ("chest_wait", nil), ("responsive_patient", nil), ("handoff", nil),
]

/// The walk a person takes, so the why panel and the log are what they'd really be.
@MainActor
private func walk(_ fixture: Fixture, to id: String) {
    let coordinator = fixture.coordinator
    coordinator.perform(.yes)
    switch id {
    case "chest_scan": [HumanAction.triageChest, .done, .yes, .scan].forEach(coordinator.perform)
    case "limb_start": coordinator.perform(.triageLimb)
    case "limb_flags": [HumanAction.triageLimb, .done].forEach(coordinator.perform)
    case "limb_splint": [HumanAction.triageLimb, .done, .no].forEach(coordinator.perform)
    case "limb_wait": [HumanAction.triageLimb, .done, .no, .done].forEach(coordinator.perform)
    case "limb_danger": [HumanAction.triageLimb, .done, .yes].forEach(coordinator.perform)
    case "choke_back_blows": [HumanAction.triageChoking, .no].forEach(coordinator.perform)
    case "choke_thrusts": [HumanAction.triageChoking, .no, .done].forEach(coordinator.perform)
    default: break
    }
    #expect(coordinator.state.stateID == id)
}

@MainActor
@Suite struct CameraTapTests {
    private func begun(camera: Bool = true, canLocate: Bool = false) throws -> Fixture {
        let fixture = try Fixture(canLocate: canLocate, arSupported: camera, cameraAllowed: camera, bundle: try mergedBundle())
        fixture.coordinator.beginRescue()
        return fixture
    }

    /// Past the longest settle window, a question's, and short of any limb step's timer.
    private func settle(_ fixture: Fixture) {
        fixture.run(seconds: 2.2)
    }

    /// A new target would have to say what it does with a tap.
    @Test func everyOtherTargetIsCovered() {
        let covered = Set(otherTargets.compactMap(\.1))
        #expect(covered.union([.injurySite]) == Set(OverlayTarget.allCases))
    }

    @Test(arguments: otherTargets)
    func aTapDoesNothingAnywhereElse(id: String, target: OverlayTarget?) async throws {
        let fixture = try begun()
        fixture.coordinator.force(stateID: id)
        #expect(fixture.coordinator.state.stateID == id)
        settle(fixture)
        #expect(fixture.coordinator.overlayTarget == target)
        #expect(!fixture.coordinator.acceptsInjuryTap)

        fixture.coordinator.tapCamera(at: CGPoint(x: 100, y: 300))
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.vision.pinTaps.isEmpty)
        #expect(fixture.coordinator.pinMessage == nil)
    }

    @Test(arguments: limbSteps)
    func aLimbStepTakesATap(id: String) async throws {
        let fixture = try begun()
        walk(fixture, to: id)
        settle(fixture)
        #expect(fixture.coordinator.overlayTarget == .injurySite)
        #expect(fixture.coordinator.acceptsInjuryTap)
        let point = CGPoint(x: 100, y: 300)
        fixture.coordinator.tapCamera(at: point)
        try await waitUntil("the tap reached vision") { fixture.vision.pinTaps == [point] }
        #expect(fixture.coordinator.state.stateID == id, "a tap on the camera moves no step")
    }

    /// The Done row goes when the step changes, the band grows into its place, and a second tap aimed at
    /// Done would move the pin and restart its time.
    @Test func aTapAsTheStepChangesIsIgnoredLikeTheButtons() async throws {
        let fixture = try begun()
        walk(fixture, to: "limb_splint")
        settle(fixture)
        fixture.coordinator.perform(.done)
        #expect(fixture.coordinator.state.stateID == "limb_wait")
        #expect(fixture.coordinator.stepIsSettling)
        fixture.coordinator.tapCamera(at: CGPoint(x: 100, y: 300))
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.vision.pinTaps.isEmpty)
        #expect(fixture.coordinator.pinMessage == nil)

        fixture.run(seconds: 0.8)
        fixture.coordinator.tapCamera(at: CGPoint(x: 100, y: 300))
        try await waitUntil("the tap reached vision") { fixture.vision.pinTaps.count == 1 }
    }

    /// On the danger step hands go on the wound, so the pin doesn't say to keep it as found or ask for a tap.
    @Test(arguments: limbSteps)
    func thePinsWordsFitTheStep(id: String) throws {
        let fixture = try begun()
        walk(fixture, to: id)
        let danger = id == "limb_danger"
        #expect(fixture.coordinator.pinLabel == (danger ? "Possible break" : "Possible break. Keep as found"))
        #expect(fixture.coordinator.invitesInjuryTap == !danger)
        #expect(fixture.coordinator.acceptsInjuryTap, "a tap still places one")
        #expect(!fixture.coordinator.pinLabel.lowercased().contains("fracture"))
    }

    @Test func theDangerStepReachedByAReportSaysTheSame() throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        coordinator.perform(.yes)
        coordinator.dispatch(.model(ModelProposal(
            action: .reportFinding(.heavyBleeding, source: .heard, confidence: .high),
            stateVersion: coordinator.state.version,
            issuedAt: fixture.clock.now
        )))
        #expect(coordinator.state.stateID == "limb_danger")
        #expect(coordinator.pinLabel == "Possible break")
        #expect(!coordinator.invitesInjuryTap)
    }

    /// AR stopped for heat or a failure leaves nothing to aim at, so the panels take their room back.
    @Test(arguments: [VisionStatus.shedForHeat, .failed])
    func aCameraThatStopsGivesTheRoomBack(status: VisionStatus) async throws {
        let fixture = try begun()
        walk(fixture, to: "limb_wait")
        settle(fixture)
        #expect(fixture.coordinator.leavesRoomForCamera && fixture.coordinator.acceptsInjuryTap)

        fixture.vision.setStatus(status)
        fixture.coordinator.tick()
        #expect(!fixture.coordinator.leavesRoomForCamera)
        #expect(!fixture.coordinator.acceptsInjuryTap)
        // Marks that go with the camera aren't lost tracking, so nothing says to hold the phone steady.
        #expect(!fixture.coordinator.arContext.cameraLive)
        fixture.coordinator.tapCamera(at: CGPoint(x: 100, y: 300))
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.vision.pinTaps.isEmpty)
        #expect(fixture.coordinator.pinMessage == nil)

        fixture.vision.setStatus(.running)
        fixture.coordinator.tick()
        #expect(fixture.coordinator.leavesRoomForCamera && fixture.coordinator.acceptsInjuryTap)
        #expect(fixture.coordinator.arContext.cameraLive)
    }

    // MARK: - Start CPR after a report flips the panel

    /// A report swaps a camera step's panel for the arrest one, whose Start CPR sits where the band and the
    /// step's rows were. A tap already on its way there can't have read it.
    @Test(arguments: [Finding.abnormalBreathing, .unresponsive])
    func startCPRWaitsOutTheFlipFromAnAwakeStep(finding: Finding) throws {
        let fixture = try begun()
        let coordinator = fixture.coordinator
        walk(fixture, to: "limb_wait")
        settle(fixture)
        coordinator.dispatch(.model(ModelProposal(
            action: .reportFinding(finding, source: .heard, confidence: .high),
            stateVersion: coordinator.state.version,
            issuedAt: fixture.clock.now
        )))
        #expect(coordinator.state.stateID == "intake_breathing")
        coordinator.performPrimary(.startCpr)
        #expect(coordinator.state.stateID == "intake_breathing")

        fixture.run(seconds: 0.6)
        coordinator.performPrimary(.startCpr)
        #expect(coordinator.state.stateID == "compressions")
    }

    @Test func onAnArrestOnlyRescueStartCPRNeverWaits() throws {
        for bundle in [try shippedBundle(), try mergedBundle()] {
            let first = try Fixture(bundle: bundle)
            first.coordinator.beginRescue()
            first.coordinator.performPrimary(.startCpr)
            #expect(first.coordinator.state.stateID == "compressions")

            let asked = try Fixture(bundle: bundle)
            asked.coordinator.beginRescue()
            asked.coordinator.perform(.no)
            #expect(asked.coordinator.state.stateID == "intake_breathing")
            asked.coordinator.performPrimary(.startCpr)
            #expect(asked.coordinator.state.stateID == "compressions")
        }
    }

    @Test func withNoCameraThereIsNothingToTapAndTheFlowRunsAnyway() async throws {
        let fixture = try begun(camera: false)
        walk(fixture, to: "limb_start")
        #expect(!fixture.coordinator.acceptsInjuryTap)
        fixture.coordinator.tapCamera(at: .zero)
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.vision.pinTaps.isEmpty)

        fixture.coordinator.perform(.done)
        #expect(fixture.coordinator.state.stateID == "limb_flags")
    }

    /// AR gates nothing, with nobody tapping and with every tap failing.
    @Test func aFailingPinHoldsUpNoStep() async throws {
        let fixture = try begun()
        fixture.vision.setPinResult(.notPlaced)
        walk(fixture, to: "limb_start")
        settle(fixture)
        fixture.coordinator.tapCamera(at: .zero)
        try await waitUntil("the failure came back") { fixture.coordinator.pinMessage != nil }
        fixture.coordinator.perform(.done)
        #expect(fixture.coordinator.state.stateID == "limb_flags")
    }

    @Test func aFailedTapSaysSoBriefly() async throws {
        let fixture = try begun()
        fixture.vision.setPinResult(.notPlaced)
        walk(fixture, to: "limb_wait")
        settle(fixture)
        fixture.coordinator.tapCamera(at: .zero)
        try await waitUntil("the failure came back") { fixture.coordinator.pinMessage != nil }
        #expect(fixture.coordinator.pinMessage?.text == "Couldn't place the pin. Tap again.")

        fixture.run(seconds: 2.5)
        #expect(fixture.coordinator.pinMessage != nil)
        fixture.run(seconds: 1)
        #expect(fixture.coordinator.pinMessage == nil)
    }

    @Test func theMessageGoesWithAGoodTapOrWithTheStep() async throws {
        let fixture = try begun()
        fixture.vision.setPinResult(.notPlaced)
        walk(fixture, to: "limb_wait")
        settle(fixture)
        fixture.coordinator.tapCamera(at: .zero)
        try await waitUntil("the failure came back") { fixture.coordinator.pinMessage != nil }

        fixture.vision.setPinResult(.placed)
        fixture.coordinator.tapCamera(at: .zero)
        try await waitUntil("the good tap came back") { fixture.coordinator.pinMessage == nil }

        fixture.vision.setPinResult(.notPlaced)
        fixture.coordinator.tapCamera(at: .zero)
        try await waitUntil("the failure came back") { fixture.coordinator.pinMessage != nil }
        fixture.coordinator.perform(.patientUnresponsive)
        #expect(fixture.coordinator.pinMessage == nil)
    }

    @Test func aTapALaterOneReplacedSaysNothing() async throws {
        let fixture = try begun()
        fixture.vision.setPinResult(.superseded)
        walk(fixture, to: "limb_wait")
        settle(fixture)
        fixture.coordinator.tapCamera(at: .zero)
        try await waitUntil("the tap reached vision") { fixture.vision.pinTaps.count == 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.coordinator.pinMessage == nil)
    }

    // MARK: - Who gives up room

    @Test(arguments: ["chest_scan"] + limbSteps)
    func aCameraStepLeavesRoomOnlyWithACamera(id: String) throws {
        let with = try begun()
        walk(with, to: id)
        #expect(with.coordinator.leavesRoomForCamera)
        #expect(with.coordinator.marksKeepToFreeArea)

        let without = try begun(camera: false)
        walk(without, to: id)
        #expect(!without.coordinator.leavesRoomForCamera)
    }

    /// The rest of the arrest path keeps its full panels, the scan's arrow included. The hands and the
    /// pads on the body give room, below, and so does compressions while the hands guide is up.
    @Test(arguments: ["resource_scan", "compressions_aed", "triage", "chest_wait", "chest_call", "responsive_patient"])
    func noOtherStepGivesUpRoom(id: String) throws {
        let fixture = try begun()
        fixture.coordinator.force(stateID: id)
        #expect(fixture.coordinator.state.stateID == id)
        #expect(!fixture.coordinator.leavesRoomForCamera)
    }

    @Test(arguments: ["place_hands", "pads"])
    func theHandsAndPadsLeaveRoomOnlyWithACamera(id: String) throws {
        let with = try begun()
        with.coordinator.force(stateID: id)
        #expect(with.coordinator.state.stateID == id)
        #expect(with.coordinator.leavesRoomForCamera)
        #expect(with.coordinator.drawsOnBody)

        let without = try begun(camera: false)
        without.coordinator.force(stateID: id)
        #expect(!without.coordinator.leavesRoomForCamera)
    }

    /// "Stick the pads where the pictures show" needs a picture. The diagram only goes once the overlay
    /// has drawn both pads inside the band, and a pose dropout under a second doesn't blink it back.
    @Test func thePadsDiagramGoesOnlyWhenThePadsAreDrawnInTheBand() throws {
        let fixture = try begun()
        fixture.coordinator.force(stateID: "pads")
        let view = CGSize(width: 400, height: 800)
        let band = CGRect(x: 0, y: 100, width: 400, height: 300)
        func drawn(at y: CGFloat) -> ARScene {
            func quad(_ c: CGPoint) -> [CGPoint] {
                [CGPoint(x: c.x - 0.09, y: c.y - 0.03), CGPoint(x: c.x + 0.09, y: c.y - 0.03), CGPoint(x: c.x + 0.09, y: c.y + 0.03), CGPoint(x: c.x - 0.09, y: c.y + 0.03)]
            }
            let zones = [
                ARZoneInput(kind: .pad(1), shape: .quad(quad(CGPoint(x: 0.42, y: y))), axis: 0, isLocked: true),
                ARZoneInput(kind: .pad(2), shape: .quad(quad(CGPoint(x: 0.62, y: y + 0.1))), axis: 0, isLocked: true),
            ]
            return ARSceneBuilder.build(overlay: .empty, zones: zones, context: ARContext(target: .padZones), band: band, view: view)
        }
        let coordinator = fixture.coordinator
        #expect(!coordinator.arDrawsPads, "nothing drawn yet")

        coordinator.noteDrawn(drawn(at: 0.7))
        #expect(!coordinator.arDrawsPads, "under the deck, so only pointed at")
        coordinator.noteDrawn(drawn(at: 0.42))
        #expect(!coordinator.arDrawsPads, "pad 2 is cut away by the deck")

        coordinator.noteDrawn(drawn(at: 0.25))
        #expect(coordinator.arDrawsPads)
        coordinator.noteDrawn(ARScene(band: band))
        fixture.clock.advance(0.5)
        #expect(coordinator.arDrawsPads, "a dropout doesn't bring the diagram back")
        fixture.clock.advance(AppCoordinator.padsGuideHold)
        #expect(!coordinator.arDrawsPads)
    }

    // MARK: - The hands at the start of compressions

    /// Start CPR never shows place_hands, so its edge's hands line opens the chest zone for 8 s.
    @Test func startCPROpensTheHandsGuideForEightSeconds() throws {
        let fixture = try Fixture(arSupported: true, cameraAllowed: true)
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.startCpr)
        #expect(coordinator.state.stateID == "compressions")
        #expect(fixture.audio.played.contains("hands_center"))
        #expect(fixture.vision.handsGuides == [8])
        #expect(coordinator.showsHandsGuide)
        #expect(coordinator.leavesRoomForCamera)
        #expect(coordinator.pulseDocked, "the beat moves aside for the hands")
        #expect(coordinator.arContext.handsGuide)

        fixture.run(seconds: 7)
        #expect(coordinator.showsHandsGuide)
        fixture.run(seconds: 1.2)
        #expect(!coordinator.showsHandsGuide)
        #expect(!coordinator.leavesRoomForCamera, "the full panels come back")
        #expect(coordinator.pulseDocked, "the beat has one place, the corner")
    }

    /// The timer out of place_hands has already shown the hands, and says nothing on its edge.
    @Test func compressionsFromPlaceHandsOpensNoGuide() throws {
        let fixture = try Fixture(arSupported: true, cameraAllowed: true)
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.force(stateID: "place_hands")
        coordinator.perform(.done)
        #expect(coordinator.state.stateID == "compressions")
        #expect(fixture.vision.handsGuides.isEmpty)
        #expect(!coordinator.leavesRoomForCamera)
    }

    @Test func noCameraNoGuide() throws {
        let fixture = try Fixture()
        fixture.coordinator.beginRescue()
        fixture.coordinator.perform(.startCpr)
        #expect(fixture.coordinator.state.stateID == "compressions")
        #expect(fixture.vision.handsGuides.isEmpty)
        #expect(!fixture.coordinator.showsHandsGuide)
    }

    /// Any later step ends it, as vision does on every overlay change.
    @Test func theNextStepEndsTheGuide() throws {
        let fixture = try Fixture(arSupported: true, cameraAllowed: true)
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.startCpr)
        #expect(coordinator.showsHandsGuide)
        coordinator.perform(.scan)
        #expect(coordinator.state.stateID == "resource_scan")
        #expect(!coordinator.showsHandsGuide)
        #expect(!fixture.vision.showsHandsGuide)
    }
}

@MainActor
@Suite struct AwakeAEDTests {
    private func begun(canLocate: Bool, camera: Bool = true) throws -> Fixture {
        let fixture = try Fixture(canLocate: canLocate, arSupported: camera, cameraAllowed: camera, bundle: try mergedBundle())
        fixture.coordinator.beginRescue()
        return fixture
    }

    private func lastPolicy(_ fixture: Fixture) -> RuntimePolicy? {
        fixture.vision.applied.reversed().lazy.compactMap { if case let .policyChanged(policy) = $0 { policy } else { nil } }.first
    }

    // MARK: - With the key

    @Test func theScanLocatesAtOnceAndStartsNoBurst() throws {
        let fixture = try begun(canLocate: true)
        walk(fixture, to: "chest_scan")
        #expect(fixture.vision.locateCount == 1)
        #expect(fixture.vision.bursts == 0)
        #expect(fixture.gate.framesOpen, "the locator's own check at the last moment has to pass")
        #expect(lastPolicy(fixture)?.frameUplink == true)
        #expect(lastPolicy(fixture)?.frameBurstsOnly == true)
        #expect(lastPolicy(fixture)?.aedFindsCarry == true)
    }

    @Test func aMissTriesAgainUntilTheStepEnds() throws {
        let fixture = try begun(canLocate: true)
        walk(fixture, to: "chest_scan")
        fixture.vision.setAEDStatus(.notFound)
        fixture.run(seconds: 2.2)
        #expect(fixture.vision.locateCount == 2)

        fixture.vision.setAEDStatus(.located)
        fixture.run(seconds: 5)
        #expect(fixture.vision.locateCount == 2)

        fixture.vision.setAEDStatus(.notFound)
        fixture.coordinator.perform(.done)
        #expect(fixture.coordinator.state.stateID == "chest_wait")
        #expect(!fixture.gate.framesOpen)
        fixture.run(seconds: 5)
        #expect(fixture.vision.locateCount == 2)
    }

    /// The step's timer waits on the dispatcher sheet, and frames stay open for it, so retries would go on
    /// for as long as the sheet did.
    @Test func theDispatcherSheetHoldsTheRetriesWithTheTimer() throws {
        let fixture = try begun(canLocate: true)
        walk(fixture, to: "chest_scan")
        fixture.vision.setAEDStatus(.notFound)
        fixture.coordinator.setDispatcher(open: true)
        fixture.run(seconds: 30)
        #expect(fixture.coordinator.state.stateID == "chest_scan", "the step waited too")
        #expect(fixture.vision.locateCount == 1)

        fixture.coordinator.setDispatcher(open: false)
        fixture.run(seconds: 1)
        #expect(fixture.vision.locateCount == 2)
    }

    @Test func aCallClosesTheFramesTheLocatorWouldUse() throws {
        let fixture = try begun(canLocate: true)
        walk(fixture, to: "chest_scan")
        fixture.coordinator.dispatch(.callChanged(active: true))
        #expect(!fixture.gate.framesOpen)
    }

    // MARK: - With no key

    @Test func noKeyMeansNoLocateAndNoClaimOfOne() throws {
        let fixture = try begun(canLocate: false)
        walk(fixture, to: "chest_scan")
        #expect(fixture.vision.locateCount == 0)
        fixture.run(seconds: 5)
        #expect(fixture.vision.locateCount == 0)
        #expect(!fixture.audio.played.contains("aed_found"))
        #expect(fixture.coordinator.instruction == "Sweep the phone around. Look for an AED, in case they collapse.")
        fixture.coordinator.perform(.done)
        #expect(fixture.coordinator.state.stateID == "chest_wait", "the scan gates nothing")
    }

    // MARK: - The line

    @Test func theAwakeLineGoesOutAndStaysOnTheScreen() throws {
        let fixture = try begun(canLocate: true)
        walk(fixture, to: "chest_scan")
        fixture.coordinator.dispatch(.model(ModelProposal(action: .reportResources([.aed]), stateVersion: fixture.coordinator.state.version, issuedAt: fixture.clock.now)))
        #expect(fixture.audio.played.last == "aed_found")
        #expect(!fixture.audio.played.contains("aed_spotted"))
        #expect(fixture.coordinator.prompt?.text == fixture.coordinator.engine.bundle.text(forPhrase: "aed_found"))
    }

    // MARK: - After a collapse

    @Test func theArrowMayShowOnlyInCompressionsAfterAnAwakeState() throws {
        let fixture = try begun(canLocate: true)
        walk(fixture, to: "chest_scan")
        #expect(!fixture.coordinator.mayShowCarriedAED)

        fixture.coordinator.perform(.patientUnresponsive)
        #expect(fixture.coordinator.state.stateID == "intake_breathing")
        #expect(!fixture.coordinator.mayShowCarriedAED)
        #expect(!fixture.coordinator.marksKeepToFreeArea)
        #expect(lastPolicy(fixture)?.showsCarriedAED == false)

        fixture.coordinator.perform(.startCpr)
        #expect(fixture.coordinator.state.stateID == "compressions")
        #expect(fixture.coordinator.mayShowCarriedAED)
        #expect(fixture.coordinator.marksKeepToFreeArea)
        #expect(lastPolicy(fixture)?.showsCarriedAED == true)
        #expect(fixture.coordinator.leavesRoomForCamera, "the hands guide first, and the arrow waits for it")
        fixture.run(seconds: 8.2)
        #expect(fixture.coordinator.mayShowCarriedAED)
        #expect(!fixture.coordinator.leavesRoomForCamera, "then the arrest panels are as they were")

        fixture.coordinator.perform(.aedHere)
        fixture.coordinator.perform(.emsArrived)
        fixture.coordinator.perform(.resumeCpr)
        #expect(fixture.coordinator.state.stateID == "compressions")
        #expect(!fixture.coordinator.mayShowCarriedAED, "the AED came")
        #expect(lastPolicy(fixture)?.showsCarriedAED == false)
    }

    @Test func anArrestOnlyRescueNeverRedrawsForIt() throws {
        for bundle in [try shippedBundle(), try mergedBundle()] {
            let fixture = try Fixture(canLocate: true, arSupported: true, cameraAllowed: true, bundle: bundle)
            let coordinator = fixture.coordinator
            coordinator.beginRescue()
            coordinator.perform(.startCpr)
            #expect(coordinator.state.stateID == "compressions")
            #expect(!coordinator.mayShowCarriedAED)
            #expect(coordinator.showsHandsGuide, "the hands guide's chest is the only mark")
            fixture.run(seconds: 8.2)
            #expect(!coordinator.marksKeepToFreeArea)

            coordinator.perform(.scan)
            #expect(!coordinator.marksKeepToFreeArea, "the arrest scan's arrow falls where it falls")
            coordinator.perform(.done)
            #expect(coordinator.state.stateID == "compressions")
            #expect(!coordinator.mayShowCarriedAED)
            #expect(lastPolicy(fixture)?.aedFindsCarry == false)
        }
    }
}

@MainActor
@Suite struct HandoffResumeLabelTests {
    private func title(_ fixture: Fixture) -> String? {
        fixture.coordinator.controls.first { $0.action == .resumeCpr }?.title
    }

    @Test func aPatientWhoNeverHadCPRIsNotResumingIt() throws {
        let fixture = try Fixture(bundle: try mergedBundle())
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        [HumanAction.yes, .triageChest, .emsArrived].forEach(coordinator.perform)
        #expect(coordinator.state.stateID == "handoff")
        #expect(title(fixture) == "Start CPR")

        coordinator.perform(.resumeCpr)
        #expect(coordinator.state.stateID == "compressions", "the label changes and the edge doesn't")

        coordinator.perform(.emsArrived)
        #expect(title(fixture) == "Resume CPR")
    }

    @Test func triageCountsAsAwakeWithNoFlowEntered() throws {
        let fixture = try Fixture(bundle: try mergedBundle())
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        [HumanAction.yes, .emsArrived].forEach(coordinator.perform)
        #expect(coordinator.state.stateID == "handoff")
        #expect(title(fixture) == "Start CPR")
    }

    @Test func anAwakeRescueThatReachedCPRResumesIt() throws {
        let fixture = try Fixture(bundle: try mergedBundle())
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        [HumanAction.yes, .triageLimb, .startCpr, .emsArrived].forEach(coordinator.perform)
        #expect(coordinator.state.stateID == "handoff")
        #expect(title(fixture) == "Resume CPR")
    }

    /// An arrest rescue reads as it always has, including the two routes that reach the card with no CPR.
    @Test func anArrestOnlyRescueReadsAsItAlwaysHas() throws {
        for bundle in [try shippedBundle(), try mergedBundle()] {
            let cpr = try Fixture(bundle: bundle)
            cpr.coordinator.beginRescue()
            [HumanAction.startCpr, .emsArrived].forEach(cpr.coordinator.perform)
            #expect(title(cpr) == "Resume CPR")

            let special = try Fixture(bundle: bundle)
            special.coordinator.beginRescue()
            [HumanAction.notAdult, .emsArrived].forEach(special.coordinator.perform)
            #expect(special.coordinator.state.stateID == "handoff")
            #expect(title(special) == "Resume CPR")

            let watched = try Fixture(bundle: bundle)
            watched.coordinator.beginRescue()
            [HumanAction.no, .yes, .patientAwake, .emsArrived].forEach(watched.coordinator.perform)
            #expect(watched.coordinator.state.stateID == "handoff")
            #expect(title(watched) == "Resume CPR")
        }
    }
}

@Suite struct MarkPlacementTests {
    private let view = CGSize(width: 400, height: 800)
    private let free = CGRect(x: 0, y: 300, width: 400, height: 200)
    private let size = CGSize(width: 36, height: 36)

    private func place(_ position: CGPoint, isOnScreen: Bool = true, angle: Double = 0.25, free: CGRect?) -> MarkPlacement {
        MarkPlacement.place(position: position, isOnScreen: isOnScreen, angle: angle, view: view, free: free, size: size)
    }

    @Test func withNoFreeAreaAMarkFallsWhereItFalls() {
        let mark = place(CGPoint(x: 0.5, y: 0.1), free: nil)
        #expect(mark == MarkPlacement(center: CGPoint(x: 200, y: 80), angle: 0.25, isOnTarget: true))
        #expect(!place(CGPoint(x: 0.92, y: 0.5), isOnScreen: false, free: nil).isOnTarget)
    }

    @Test func insideTheBandAMarkIsOnItsTarget() {
        let mark = place(CGPoint(x: 0.25, y: 0.5), free: free)
        #expect(mark == MarkPlacement(center: CGPoint(x: 100, y: 400), angle: 0.25, isOnTarget: true))
    }

    @Test func nearTheBandsEdgeItStaysOnTargetAndWhole() {
        let mark = place(CGPoint(x: 0.25, y: 0.376), free: free)
        #expect(mark.isOnTarget)
        #expect(mark.center.y == 318)
    }

    @Test func behindAPanelItPointsTheWayFromInsideTheBand() {
        let above = place(CGPoint(x: 0.5, y: 0.1), free: free)
        #expect(!above.isOnTarget)
        #expect(above.center == CGPoint(x: 200, y: 318))
        #expect(abs(above.angle - -Double.pi / 2) < 1e-6, "straight up")

        let below = place(CGPoint(x: 0.5, y: 0.9), free: free)
        #expect(!below.isOnTarget)
        #expect(below.center == CGPoint(x: 200, y: 482))
        #expect(abs(below.angle - Double.pi / 2) < 1e-6, "straight down")
    }

    @Test func offScreenItKeepsVisionsDirection() {
        let mark = place(CGPoint(x: 0.92, y: 0.5), isOnScreen: false, angle: 0.25, free: free)
        #expect(!mark.isOnTarget)
        #expect(mark.angle == 0.25)
        #expect(free.contains(mark.center))
    }

    @Test func aBandSmallerThanTheMarkCentersIt() {
        let thin = CGRect(x: 0, y: 300, width: 400, height: 10)
        #expect(place(CGPoint(x: 0.5, y: 0.1), free: thin).center == CGPoint(x: 200, y: 305))
    }

    /// The PUSH pulse sits mid-band in compressions, and an AED above or below the view would otherwise put
    /// the arrow on it every time.
    @Test func aMarkGoesBesideAColumnItMustKeepOff() {
        let column: ClosedRange<CGFloat> = 87...313
        func place(_ position: CGPoint, isOnScreen: Bool = false, angle: Double) -> MarkPlacement {
            MarkPlacement.place(position: position, isOnScreen: isOnScreen, angle: angle, view: view, free: free, size: size, keepingOff: column)
        }

        let above = place(CGPoint(x: 0.5, y: 0.08), angle: -.pi / 2)
        #expect(above == MarkPlacement(center: CGPoint(x: 313, y: 318), angle: -.pi / 2, isOnTarget: false))
        let upLeft = place(CGPoint(x: 0.45, y: 0.08), angle: -.pi * 0.6)
        #expect(upLeft.center == CGPoint(x: 87, y: 318), "on the side it points to")
        let below = place(CGPoint(x: 0.5, y: 0.92), angle: .pi / 2)
        #expect(below.center == CGPoint(x: 313, y: 482))

        let behind = place(CGPoint(x: 0.45, y: 0.5), isOnScreen: true, angle: 0)
        #expect(behind.center == CGPoint(x: 87, y: 400))
        #expect(!behind.isOnTarget)
        #expect(abs(behind.angle) < 1e-6, "pointing back at it")

        let clear = place(CGPoint(x: 0.1, y: 0.5), isOnScreen: true, angle: 0)
        #expect(clear == self.place(CGPoint(x: 0.1, y: 0.5), angle: 0, free: free), "nothing to move for")
    }

    /// A band this short has nowhere to put a mark but on the buttons.
    @Test func noRoomInTheBandMeansNoMark() {
        #expect(MarkPlacement.hasRoom(for: 36, in: nil), "no band, as on the arrest path")
        #expect(MarkPlacement.hasRoom(for: 36, in: CGRect(x: 0, y: 300, width: 400, height: 36)))
        #expect(!MarkPlacement.hasRoom(for: 36, in: CGRect(x: 0, y: 300, width: 400, height: 35)))
        #expect(!MarkPlacement.hasRoom(for: 36, in: .zero))
    }

    @Test func theLabelStaysInTheBand() {
        let label = CGSize(width: 232, height: 24)
        let middle = MarkPlacement.labelCenter(mark: CGPoint(x: 200, y: 400), markHeight: 36, label: label, free: free)
        #expect(middle == CGPoint(x: 200, y: 432), "under the mark")

        let low = MarkPlacement.labelCenter(mark: CGPoint(x: 200, y: 482), markHeight: 36, label: label, free: free)
        #expect(low.y == 450, "over it, with no room under")

        let wide = MarkPlacement.labelCenter(mark: CGPoint(x: 395, y: 400), markHeight: 36, label: label, free: free)
        #expect(wide.x + label.width / 2 <= free.maxX)
        let left = MarkPlacement.labelCenter(mark: CGPoint(x: 5, y: 400), markHeight: 36, label: label, free: free)
        #expect(left.x - label.width / 2 >= free.minX)
    }
}

/// Sizes with the safe area taken off: a 17 Pro, and the smallest phone that runs this.
private let screens: [(width: CGFloat, height: CGFloat, least: CGFloat)] = [(402, 778, 240), (375, 647, 100)]
/// The arrest panels' buttons stay at their gloved-hand heights, so these get less than an awake step.
private let arrestScreens: [(width: CGFloat, height: CGFloat, least: CGFloat)] = [(402, 778, 160), (375, 647, 100)]

private final class MeasuredArea: Sendable {
    let rect = Mutex(CGRect.zero)
}

/// The real screen in a real window, with the camera's part faked. The camera can only be seen and
/// tapped between the panels, so a band too thin to aim in leaves the pin with no way on.
@MainActor
@Suite(.serialized) struct CameraBandLayoutTests {
    private func band(_ coordinator: AppCoordinator, width: CGFloat, height: CGFloat) async throws -> CGRect {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let measured = MeasuredArea()
        window.rootViewController = UIHostingController(rootView: MainScreen(coordinator: coordinator)
            .onPreferenceChange(FreeCameraArea.self) { area in measured.rect.withLock { $0 = area } }
            .frame(width: width, height: height)
            .clipped())
        window.isHidden = false
        window.layoutIfNeeded()
        // The why panel fits itself over a pass or two, so one good reading isn't yet the last.
        try await Task.sleep(for: .milliseconds(300))
        window.isHidden = true
        return measured.rect.withLock { $0 }
    }

    @Test(arguments: ["chest_scan"] + limbSteps)
    func aCameraStepLeavesABandToAimIn(id: String) async throws {
        for screen in screens {
            let fixture = try Fixture(arSupported: true, cameraAllowed: true, bundle: try mergedBundle())
            fixture.coordinator.beginRescue()
            walk(fixture, to: id)
            let area = try await band(fixture.coordinator, width: screen.width, height: screen.height)
            #expect(area.height >= screen.least, "\(id) at \(Int(screen.width))x\(Int(screen.height)): \(area.height)")
            #expect(area.width == screen.width)
        }
    }

    /// The hands and the pads go on a body lying in the band, so the compact deck has to leave one.
    /// Compressions counts while the hands guide is up, its first 8 s from Start CPR.
    @Test(arguments: ["place_hands", "pads", "compressions"])
    func theArrestHandsAndPadsLeaveABandToSeeThemIn(id: String) async throws {
        for screen in arrestScreens {
            let fixture = try Fixture(arSupported: true, cameraAllowed: true, bundle: try mergedBundle())
            let coordinator = fixture.coordinator
            coordinator.beginRescue()
            if id == "compressions" {
                coordinator.perform(.startCpr)
                #expect(coordinator.showsHandsGuide)
            } else {
                coordinator.force(stateID: id)
            }
            #expect(coordinator.state.stateID == id)
            #expect(coordinator.leavesRoomForCamera)
            let area = try await band(coordinator, width: screen.width, height: screen.height)
            #expect(area.height >= screen.least, "\(id) at \(Int(screen.width))x\(Int(screen.height)): \(area.height)")
            #expect(area.width == screen.width)
        }
    }
}
