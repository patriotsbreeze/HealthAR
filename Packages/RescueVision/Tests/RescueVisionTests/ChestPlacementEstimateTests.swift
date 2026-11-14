import CoreGraphics
import Foundation
import RescueCore
import Testing
import simd
@testable import RescueVision

private let subject = person(center: [0.5, 0.55], axisDegrees: 0, aspect: 4.0 / 3)

private func makeChestSession(_ clock: TestClock, people: [DetectedPerson] = [subject]) -> VisionSession {
    let session = VisionSession(
        locator: FixedLocator(box: nil), driver: FakeDriver(),
        detect: { _, _ in people }, clock: { clock.now }, runsPump: false
    )
    session.viewportSize = portraitMapping.viewSize
    session.start()
    return session
}

private func process(_ session: VisionSession, depth: BodyDepth? = nil) async throws {
    let frame = try #require(session.ingest(pixels: makePixels(), pose: cameraPose(), tracking: .normal,
        imageToView: portraitMapping.imageToView, bodyDepth: depth))
    #expect(await !session.process(frame), "local recognition must not open the uplink")
}

@Test func sternumRegionWorksWithoutDepthOrTheBlenderAsset() async throws {
    let clock = TestClock()
    let session = makeChestSession(clock)
    session.apply(.overlay(.chestCenter))
    try await process(session)
    let marker = try #require(session.overlay().sternumEstimate)
    let target = try #require(TorsoMap.target(for: subject.torso, imageAspect: 4.0 / 3))
    #expect(marker == portraitMapping.ring(for: target))
    #expect(!session.overlay().patientIn3D)
    #expect(session.overlay().chestEstimateLabel == "Estimated sternum region - Not anatomically verified")
    #expect(session.chestSurfacePlacement() == nil)
}

@Test func markerNeverSuggestsCPRDuringOrdinaryCameraViewing() async throws {
    let clock = TestClock()
    let session = makeChestSession(clock)
    try await process(session)
    #expect(session.overlay().sternumEstimate == nil)
    #expect(session.chestSurfacePlacement() == nil)
    session.setGhostBeat(on: true)
    #expect(session.overlay().sternumEstimate != nil)
    session.setGhostBeat(on: false)
    #expect(session.overlay().sternumEstimate == nil)
}

@Test func sternumRegionRejectsInferredHipsAndAmbiguousPatients() async throws {
    var inferred = subject
    inferred.torsoEstimated = true
    var faint = subject
    faint.leftShoulder.confidence = 0.2
    let standing = person(center: [0.5, 0.55], axisDegrees: 90, aspect: 4.0 / 3)
    for people in [[inferred], [faint], [standing], [subject, subject]] {
        let clock = TestClock()
        let session = makeChestSession(clock, people: people)
        session.apply(.overlay(.chestCenter))
        try await process(session)
        #expect(session.overlay().sternumEstimate == nil)
        #expect(session.chestSurfacePlacement() == nil)
    }
}

@Test func freshCameraFramesDoNotReviveAnOldSternumEstimate() async throws {
    let clock = TestClock()
    let session = makeChestSession(clock)
    session.apply(.overlay(.chestCenter))
    try await process(session)
    #expect(session.overlay().sternumEstimate != nil)
    clock.advance(VisionOverlay.maxJointAge + 0.01)
    session.ingest(pixels: makePixels(), pose: cameraPose(), tracking: .normal, imageToView: portraitMapping.imageToView)
    #expect(session.overlay().sternumEstimate == nil)
    session.forgetWorld()
    #expect(session.chestSurfacePlacement() == nil)
}

@Test func chestSurfaceMarkerDoesNotRequireHipDepthOrTheBodyMesh() async throws {
    var depth = BodyDepth(width: 64, height: 48, metres: Array(repeating: 1.5, count: 64 * 48), confidence: Array(repeating: 2, count: 64 * 48))
    for hip in [subject.leftHip.position, subject.rightHip.position] {
        let x = Int(hip.x * 64), y = Int(hip.y * 48)
        for row in (y - 1)...(y + 1) {
            for column in (x - 1)...(x + 1) { depth.metres[row * 64 + column] = .nan }
        }
    }
    let clock = TestClock()
    let session = makeChestSession(clock)
    session.apply(.overlay(.chestCenter))
    try await process(session, depth: depth)
    #expect(session.patientBodyPlacement() == nil)
    #expect(session.chestSurfacePlacement() != nil)
    #expect(session.overlay().sternumEstimate != nil)
    #expect(!session.overlay().patientIn3D)
}
