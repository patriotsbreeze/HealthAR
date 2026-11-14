import Testing
import simd
@testable import RescueVision

/// A patient lying across the image, head toward -x.
private let torso = TorsoKeypoints(leftShoulder: [0.3, 0.4], rightShoulder: [0.3, 0.6], leftHip: [0.7, 0.42], rightHip: [0.7, 0.58])
private let aspect = 4.0 / 3.0

private func target() throws -> TorsoTarget {
    try #require(TorsoMap.target(for: torso, imageAspect: aspect))
}

private func guide(_ hand: SIMD2<Double>) throws -> HandGuidance? {
    HandPlacementGuide.guide(hand: hand, target: try target(), torso: torso, imageAspect: aspect)
}

@Test func aHandOnTheRingIsOnTarget() throws {
    let center = try target().center
    #expect(try guide(center)?.move == .onTarget)
    #expect(try guide(center + [0.01, 0.005])?.move == .onTarget, "a few millimetres off still counts")
}

@Test func aHandTooFarDownTheBodySlidesTowardTheHead() throws {
    let low = try target().center + [0.15, 0]
    let guidance = try #require(try guide(low))
    #expect(guidance.move == .towardHead)
    #expect(guidance.centimetres > 3)
}

@Test func aHandPastTheRingSlidesTowardTheFeet() throws {
    #expect(try guide(try target().center - [0.12, 0])?.move == .towardFeet)
}

@Test func aHandOffToOneSideMovesToTheMiddle() throws {
    #expect(try guide(try target().center + [0, 0.15])?.move == .towardMiddle)
    #expect(try guide(try target().center - [0, 0.15])?.move == .towardMiddle)
}

@Test func theHandNearestTheRingIsTheOneGuided() throws {
    let ring = try target()
    let near = SeenHand(heel: ring.center + [0.02, 0], confidence: 0.9)
    let far = SeenHand(heel: ring.center + [0.3, 0.2], confidence: 0.9)
    #expect(HandPlacementGuide.nearest([far, near], to: ring, imageAspect: aspect) == near)
}
