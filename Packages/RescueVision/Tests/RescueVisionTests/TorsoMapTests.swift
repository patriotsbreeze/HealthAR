import Testing
import simd
@testable import RescueVision

private func torso(_ person: DetectedPerson) -> TorsoKeypoints { person.torso }

@Test func targetSitsOnTheMidlineAtTheChestFraction() throws {
    let keypoints = TorsoKeypoints(
        leftShoulder: [0.3, 0.2], rightShoulder: [0.7, 0.2],
        leftHip: [0.35, 0.8], rightHip: [0.65, 0.8]
    )
    let target = try #require(TorsoMap.target(for: keypoints, imageAspect: 1))
    #expect(isClose(target.center, [0.5, 0.2 + 0.22 * 0.6]))
    #expect(isClose(target.radius, 0.6 * TorsoMap.radiusFraction))
}

@Test(arguments: [0.0, 30, 45, 90, 135, 180, 217, 270, 333])
func rotatedQuadMovesTheTargetWithIt(degrees: Double) throws {
    let target = try #require(TorsoMap.target(for: torso(person(axisDegrees: degrees)), imageAspect: 1))
    let radians = degrees * .pi / 180
    let shoulderMid = SIMD2<Double>(0.5, 0.5) - SIMD2(cos(radians), sin(radians)) * 0.2
    let expected = shoulderMid + SIMD2(cos(radians), sin(radians)) * 0.4 * 0.22
    #expect(isClose(target.center, expected))
    #expect(isClose(target.radius, 0.4 * TorsoMap.radiusFraction))
}

@Test func skewedQuadInterpolatesBilinearly() throws {
    // A keystoned, sheared quad, as from an oblique camera.
    let keypoints = TorsoKeypoints(
        leftShoulder: [0.2, 0.3], rightShoulder: [0.6, 0.1],
        leftHip: [0.3, 0.7], rightHip: [0.5, 0.6]
    )
    let target = try #require(TorsoMap.target(for: keypoints, imageAspect: 1))
    let top = SIMD2<Double>(0.4, 0.2)
    let bottom = SIMD2<Double>(0.4, 0.65)
    #expect(isClose(target.center, top + (bottom - top) * 0.22))
}

@Test func swappedLeftAndRightDoesNotMoveTheTarget() throws {
    let straight = TorsoKeypoints(
        leftShoulder: [0.3, 0.2], rightShoulder: [0.7, 0.25],
        leftHip: [0.35, 0.8], rightHip: [0.65, 0.75]
    )
    var crossed = straight
    swap(&crossed.leftHip, &crossed.rightHip)
    let a = try #require(TorsoMap.target(for: straight, imageAspect: 1))
    let b = try #require(TorsoMap.target(for: crossed, imageAspect: 1))
    #expect(isClose(a.center, b.center))
}

@Test(arguments: [0.0, 37, 90, 145])
func radiusIgnoresImageAspect(degrees: Double) throws {
    let aspect = 4.0 / 3
    let keypoints = person(axisDegrees: degrees, aspect: aspect).torso
    let target = try #require(TorsoMap.target(for: keypoints, imageAspect: aspect))
    #expect(isClose(target.radius, 0.4 * TorsoMap.radiusFraction))
}

@Test func radiusIsPalmSizedOnAnAdultTorso() throws {
    // Normalized so that a 50 cm torso is 0.5 image heights: 1 unit is 1 m here.
    let target = try #require(TorsoMap.target(for: person(axisDegrees: 0, length: 0.5, width: 0.4).torso, imageAspect: 1))
    #expect((0.06...0.09).contains(target.radius))
}

@Test func foreshortenedLengthStillGivesAFullSizedRing() throws {
    let target = try #require(TorsoMap.target(for: person(axisDegrees: 0, length: 0.2, width: 0.4).torso, imageAspect: 1))
    #expect(isClose(target.radius, 0.4 * TorsoMap.radiusFraction))
}

@Test func neverAPreciseDot() {
    #expect(TorsoMap.target(for: person(axisDegrees: 0, length: 0.05, width: 0.05).torso, imageAspect: 1) == nil)
    #expect(TorsoMap.target(for: person(axisDegrees: 0, length: 0, width: 0).torso, imageAspect: 1) == nil)
    // Wide but with no length, so the chest fraction has nothing to measure along.
    #expect(TorsoMap.target(for: person(axisDegrees: 0, length: 0.01, width: 0.4).torso, imageAspect: 1) == nil)
    #expect(TorsoMap.target(for: person(axisDegrees: 0).torso, imageAspect: 0) == nil)

    for size in stride(from: 0.1, through: 1, by: 0.05) {
        let target = TorsoMap.target(for: person(axisDegrees: 20, length: size, width: size).torso, imageAspect: 1)
        #expect((target?.radius ?? 0) >= TorsoMap.minimumTorsoSize * TorsoMap.radiusFraction * 0.99)
    }
}
