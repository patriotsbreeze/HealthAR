import CoreGraphics
import Foundation
@testable import HealthAISim
import RescueAudio
@testable import RescueCore
import RescueVision
import Testing

@MainActor
@Suite struct GhostTests {
    /// The ghost presses on the click, so it has to keep the metronome's interval.
    @Test func theGhostKeepsTheMetronomesBeat() {
        #expect(abs(VisionSession.ghostBeatInterval - ClickGenerator.beatInterval) < 1e-12)
    }

    @Test func theGhostFollowsTheMetronomeOnAndOff() throws {
        let fixture = try Fixture(arSupported: true, cameraAllowed: true)
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.startCpr)
        #expect(coordinator.state.stateID == "compressions")
        #expect(fixture.vision.ghostBeats == fixture.audio.metronome)
        #expect(fixture.vision.ghostBeats.last == true)
        #expect(coordinator.metronomeOn)
        #expect(!coordinator.overlayIdle, "the ghost redraws on every frame of the beat")

        coordinator.restartRescue()
        #expect(fixture.vision.ghostBeats.last == false)
        #expect(!coordinator.metronomeOn)
        #expect(fixture.vision.practiceClears == 1)
    }

    @Test func theGhostStandsInForThePushPulseAndThePulseComesBackWithoutIt() throws {
        let fixture = try Fixture(arSupported: true, cameraAllowed: true)
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.startCpr)
        #expect(coordinator.showsBeatPulse, "nothing placed yet, so the pulse")

        fixture.vision.setShowsGhost(true)
        fixture.run(seconds: 0.4)
        #expect(!coordinator.showsBeatPulse, "the ghost is the beat")
        #expect(coordinator.showsPulse, "the step still has a beat")
        #expect(!coordinator.pulseDocked)
        #expect(coordinator.arContext.pulse == .hidden)

        fixture.vision.setShowsGhost(false)
        fixture.run(seconds: 0.4)
        #expect(coordinator.showsBeatPulse, "lost tracking brings the pulse straight back")
    }

    @Test func noCameraKeepsThePushPulse() throws {
        let fixture = try Fixture()
        fixture.vision.setShowsGhost(true)
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.startCpr)
        fixture.run(seconds: 0.4)
        #expect(coordinator.showsBeatPulse)
    }

    @Test func thePracticePatientIsOfferedInCompressionsWithTheCameraUp() throws {
        let fixture = try Fixture(arSupported: true, cameraAllowed: true)
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        #expect(!coordinator.offersPracticePatient, "not before compressions")
        coordinator.perform(.startCpr)
        #expect(coordinator.offersPracticePatient)
    }

    @Test func noCameraOffersNoPracticePatient() throws {
        let fixture = try Fixture()
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.startCpr)
        #expect(coordinator.state.stateID == "compressions")
        #expect(!coordinator.offersPracticePatient)
    }

    @Test func placingAndRemovingThePracticePatient() async throws {
        let fixture = try Fixture(arSupported: true, cameraAllowed: true)
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.startCpr)
        coordinator.placePracticePatient(at: CGPoint(x: 200, y: 300))
        for _ in 0..<50 where !coordinator.practicePatientPlaced { await Task.yield() }
        #expect(coordinator.practicePatientPlaced)
        #expect(fixture.vision.practicePlacements == [CGPoint(x: 200, y: 300)])

        coordinator.clearPracticePatient()
        #expect(!coordinator.practicePatientPlaced)
        #expect(fixture.vision.practiceClears == 1)
    }

    @Test func noFloorLeavesTheButtonAsItWas() async throws {
        let fixture = try Fixture(arSupported: true, cameraAllowed: true)
        fixture.vision.setPracticePlaces(false)
        let coordinator = fixture.coordinator
        coordinator.beginRescue()
        coordinator.perform(.startCpr)
        coordinator.placePracticePatient(at: .zero)
        for _ in 0..<50 where fixture.vision.practicePlacements.isEmpty { await Task.yield() }
        await Task.yield()
        #expect(fixture.vision.practicePlacements.count == 1)
        #expect(!coordinator.practicePatientPlaced)
    }
}

// MARK: - Drawing

private let segment = VisionOverlay.Figure.Segment(from: CGPoint(x: 0.5, y: 0.25), to: CGPoint(x: 0.5, y: 0.5))
private let rescuer = VisionOverlay.Figure(segments: [segment], head: CGPoint(x: 0.5, y: 0.2), hands: CGPoint(x: 0.5, y: 0.5))

@Test func theGhostIsDrawnInPointsUnderTheOtherMarks() throws {
    let ghost = VisionOverlay.Ghost(rescuer: rescuer, patient: rescuer, push: 1, pointsPerMetre: 200)
    let scene = ARSceneBuilder.build(
        overlay: VisionOverlay(ghost: ghost),
        context: ARContext(),
        band: CGRect(x: 0, y: 100, width: 400, height: 300),
        view: CGSize(width: 400, height: 800)
    )
    let drawn = try #require(scene.ghost)
    #expect(scene.hasMarks)
    #expect(drawn.rescuer.segments == [.init(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 200, y: 400))])
    #expect(drawn.rescuer.hands == CGPoint(x: 200, y: 400))
    #expect(drawn.patient != nil)
    #expect(drawn.limbWidth == 16, "8 cm at 200 points a metre")
    #expect(drawn.rescuer.headRadius == 20)
}

@Test func aFarOrNearGhostKeepsItsLimbsWithinBounds() {
    for (metre, width) in [(10.0, DS.AR.Ghost.limbWidth.lowerBound), (2000.0, DS.AR.Ghost.limbWidth.upperBound)] {
        let ghost = ARSceneBuilder.ghost(VisionOverlay.Ghost(rescuer: rescuer, push: 0, pointsPerMetre: metre), view: CGSize(width: 400, height: 800))
        #expect(ghost.limbWidth == width)
    }
}

@Test func theGhostStaysSeeThrough() {
    #expect(GhostPlacement.opacity == 0.45)
    #expect(GhostPlacement.opacity + GhostPlacement.pushOpacity <= 0.6, "never strong enough to hide the person compressing")
    #expect(GhostPlacement.patientOpacity < GhostPlacement.opacity)
}

// MARK: - Coaching

@MainActor
@Test func aCorrectionShowsOnceItHoldsAndGoesOnceItsGoneForAsLong() {
    let memory = ARMemory()
    #expect(memory.heldCue(.lockElbows, now: 0) == nil)
    #expect(memory.heldCue(.lockElbows, now: 0.5) == nil, "one jittery moment isn't enough")
    #expect(memory.heldCue(.lockElbows, now: 0.8) == .lockElbows)
    #expect(memory.heldCue(nil, now: 1.0) == .lockElbows, "nor is one good moment")
    #expect(memory.heldCue(nil, now: 1.8) == nil)
    #expect(memory.heldCue(.pushFaster, now: 2.0) == nil)
    #expect(memory.heldCue(.pushFaster, now: 2.85) == .pushFaster)
}

@Test func aCorrectionTakesTheHintChip() throws {
    for cue in CompressionFeedback.Cue.allCases {
        var context = ARContext()
        context.coachingCue = cue
        let scene = ARSceneBuilder.build(
            overlay: .empty,
            context: context,
            band: CGRect(x: 0, y: 100, width: 400, height: 300),
            view: CGSize(width: 400, height: 800),
            measure: { CGSize(width: CGFloat($0.count) * 8 + 20, height: 30) }
        )
        let hint = try #require(scene.hint)
        #expect(hint.text == ARSceneBuilder.coachingText(cue))
        #expect(hint.tone == .caution)
    }
}

@Test func losingTrackingOutranksACorrection() throws {
    var context = ARContext()
    context.coachingCue = .pushFaster
    context.trackingLost = true
    let scene = ARSceneBuilder.build(
        overlay: .empty,
        context: context,
        band: CGRect(x: 0, y: 100, width: 400, height: 300),
        view: CGSize(width: 400, height: 800),
        measure: { CGSize(width: CGFloat($0.count) * 8 + 20, height: 30) }
    )
    #expect(scene.hint?.text == ARSceneBuilder.holdSteady)
}

@Test func noCorrectionEverPraises() {
    for cue in CompressionFeedback.Cue.allCases {
        let text = ARSceneBuilder.coachingText(cue).lowercased()
        #expect(!["good", "great", "perfect", "well done", "nice"].contains { text.contains($0) })
    }
}

@Test func lostTrackingDrawsNoGhost() {
    let ghost = VisionOverlay.Ghost(rescuer: rescuer, push: 0, pointsPerMetre: 200)
    var context = ARContext()
    context.trackingLost = true
    let scene = ARSceneBuilder.build(
        overlay: VisionOverlay(ghost: ghost),
        context: context,
        band: CGRect(x: 0, y: 100, width: 400, height: 300),
        view: CGSize(width: 400, height: 800)
    )
    #expect(scene.ghost == nil)
}

@Test func realisticHandsTakeOverFromTheFlatOnes() {
    var overlay = VisionOverlay.empty
    overlay.handsIn3D = true
    let scene = ARSceneBuilder.build(
        overlay: overlay,
        context: ARContext(),
        band: CGRect(x: 0, y: 100, width: 400, height: 300),
        view: CGSize(width: 400, height: 800)
    )
    #expect(scene.handsIn3D)
    #expect(!ARSceneBuilder.build(overlay: .empty, context: ARContext(), band: CGRect(x: 0, y: 100, width: 400, height: 300), view: CGSize(width: 400, height: 800)).handsIn3D)
}
