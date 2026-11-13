import Foundation
import RescueCore
import Synchronization
import Testing
import simd
@testable import RescueVision

private let wallAtMinusFour: @Sendable (WorldRay) async -> SIMD3<Float>? = { ray in
    guard ray.direction.z < 0 else { return nil }
    return ray.origin + ray.direction * ((-4 - ray.origin.z) / ray.direction.z)
}

private func frozen(
    _ pose: CameraPose = cameraPose(),
    tracking: TrackingQuality = .normal,
    rotation: CaptureRotation = .up
) -> FrozenFrame {
    FrozenFrame(
        jpeg: Data([0xFF]),
        record: FrameRecord(id: 1, timestamp: 0, pose: pose, tracking: tracking),
        rotation: rotation
    )
}

private let middle = NormalizedBox(minX: 0.4, minY: 0.4, maxX: 0.6, maxY: 0.6)!

private func locator(_ locating: any ObjectLocating, clock: TestClock = TestClock()) -> ObjectLocator {
    ObjectLocator(locator: locating, clock: { clock.now }, surface: wallAtMinusFour)
}

@Test func boxCenterBecomesAWorldPointOnTheSurface() async throws {
    let objects = locator(FixedLocator(box: middle))
    await objects.locate(frozen(), materials: [.aed])
    #expect(objects.status(.aed) == .located)
    #expect(isClose(try #require(objects.worldPoint(.aed)), [0, 0, -4]))
}

@Test func boxIsReadInTheRotatedJPEG() async throws {
    // In a portrait JPEG, the top-left corner is at capture (0, 1) with rotation .right.
    let box = try #require(NormalizedBox(minX: 0, minY: 0, maxX: 0.02, maxY: 0.02))
    let objects = locator(FixedLocator(box: box))
    await objects.locate(frozen(rotation: .right), materials: [.aed])
    let point = try #require(objects.worldPoint(.aed))
    #expect(point.x < 0, "capture x near 0 is image left")
    #expect(point.y < 0, "capture y near 1 is image bottom")
}

@Test func usesOnlyTheStoredPose() async throws {
    let stored = cameraPose(transform(rotationY: 25, position: [1, 0, 0]))
    let box = try #require(NormalizedBox(minX: 0.6, minY: 0.2, maxX: 0.8, maxY: 0.4))
    let objects = locator(FixedLocator(box: box))
    await objects.locate(frozen(stored), materials: [.aed])

    let expected = await wallAtMinusFour(stored.ray(throughImagePoint: [0.7, 0.3]))
    #expect(isClose(try #require(objects.worldPoint(.aed)), try #require(expected)))
}

@Test func notFoundKeepsAnEarlierPoint() async throws {
    let gated = GatedLocator()
    let objects = locator(gated)

    let first = Task { await objects.locate(frozen(), materials: [.aed]) }
    #expect(await waitUntil { gated.calls == 1 })
    gated.release(middle)
    await first.value
    let point = objects.worldPoint(.aed)
    #expect(point != nil)

    let second = Task { await objects.locate(frozen(), materials: [.aed]) }
    #expect(await waitUntil { gated.calls == 2 })
    gated.release(nil)
    await second.value
    #expect(objects.status(.aed) == .notFound)
    #expect(objects.worldPoint(.aed) == point)
}

@Test func noSurfaceGivesNoPoint() async throws {
    let objects = ObjectLocator(locator: FixedLocator(box: middle), surface: { _ in nil })
    await objects.locate(frozen(), materials: [.aed])
    #expect(objects.status(.aed) == .noSurface)
    #expect(objects.worldPoint(.aed) == nil)
}

@Test func poorTrackingIsRefusedBeforeSpendingACall() async {
    let gated = GatedLocator()
    let objects = locator(gated)
    await objects.locate(frozen(tracking: .limited), materials: [.aed, .towel])
    #expect(objects.status(.aed) == .unreliablePose)
    #expect(objects.status(.towel) == .unreliablePose)
    #expect(gated.calls == 0)
}

@Test func aNewerRequestWinsOverALateOne() async throws {
    let gated = GatedLocator()
    let objects = locator(gated)
    let early = Task { await objects.locate(frozen(), materials: [.aed]) }
    #expect(await waitUntil { gated.calls == 1 })
    let late = Task { await objects.locate(frozen(), materials: [.aed]) }
    #expect(await waitUntil { gated.calls == 2 })

    gated.release(nil)
    await early.value
    await late.value
    #expect(objects.status(.aed) == .notFound)
}

@Test func clearDropsAnAnswerStillOnItsWay() async throws {
    let gated = GatedLocator()
    let objects = locator(gated)
    let request = Task { await objects.locate(frozen(), materials: [.aed]) }
    #expect(await waitUntil { gated.calls == 1 })
    objects.clear()
    gated.release(middle)
    await request.value
    #expect(objects.worldPoint(.aed) == nil)
    #expect(objects.status(.aed) == .idle)
}

@Test func impossibleBoxesCannotBeBuilt() {
    #expect(NormalizedBox(minX: -0.1, minY: 0, maxX: 0.5, maxY: 0.5) == nil)
    #expect(NormalizedBox(minX: 0, minY: 0, maxX: 1.5, maxY: 0.5) == nil)
    #expect(NormalizedBox(minX: 0.5, minY: 0, maxX: 0.5, maxY: 0.5) == nil)
    #expect(NormalizedBox(minX: 0.6, minY: 0, maxX: 0.5, maxY: 0.5) == nil)
    #expect(NormalizedBox(minX: .nan, minY: 0, maxX: 0.5, maxY: 0.5) == nil)
    #expect(NormalizedBox(minX: 0, minY: 0, maxX: .infinity, maxY: 0.5) == nil)
}

// MARK: - Several materials

/// The app's locator answers one label at a time today. The default asks it once per material.
@Test func theDefaultMultiLabelLocateAsksOncePerMaterial() async throws {
    let gated = GatedLocator()
    let asking = Task { await gated.locate(jpeg: Data([0xFF]), materials: [.towel, .pillow, .towel]) }
    #expect(await waitUntil { gated.calls == 1 })
    gated.release(middle)
    #expect(await waitUntil { gated.calls == 2 })
    gated.release(nil)
    let boxes = await asking.value
    #expect(gated.labels == ["towel", "pillow"], "raw values, in order, each once")
    #expect(boxes == [.towel: middle])
}

@Test func severalMaterialsGoInOneCall() async throws {
    let left = try #require(NormalizedBox(minX: 0.1, minY: 0.4, maxX: 0.2, maxY: 0.6))
    let multi = MultiLocator([.towel: left, .pillow: middle])
    let objects = locator(multi)
    await objects.locate(frozen(), materials: [.pillow, .towel, .gloves])
    #expect(multi.calls == [[.towel, .pillow, .gloves]], "one call, in Material order")
    #expect(objects.status(.towel) == .located)
    #expect(objects.status(.pillow) == .located)
    #expect(objects.status(.gloves) == .notFound)
    #expect(objects.worldPoint(.towel) != objects.worldPoint(.pillow))
}

/// Each material keeps its own request. A newer look for the pillow doesn't void the towel's answer.
@Test func aNewerRequestForOneMaterialLeavesAnotherAlone() async throws {
    let gated = GatedLocator()
    let objects = locator(gated)
    let towel = Task { await objects.locate(frozen(), materials: [.towel]) }
    #expect(await waitUntil { gated.calls == 1 })
    let pillow = Task { await objects.locate(frozen(), materials: [.pillow]) }
    #expect(await waitUntil { gated.calls == 2 })
    gated.release(middle)
    await towel.value
    await pillow.value
    #expect(objects.status(.towel) == .located)
    #expect(objects.status(.pillow) == .located)
}

@Test func aMovableMaterialExpiresAndTheAEDDoesNot() async throws {
    let clock = TestClock()
    let objects = locator(FixedLocator(box: middle), clock: clock)
    await objects.locate(frozen(), materials: [.aed, .towel])
    #expect(objects.worldPoint(.towel) != nil)

    clock.advance(ObjectLocator.movableSeconds - 0.01)
    #expect(objects.worldPoint(.towel) != nil)
    clock.advance(0.02)
    #expect(objects.worldPoint(.towel) == nil, "it may well have been picked up")
    #expect(objects.status(.towel) == .idle, "so it is looked for again")
    #expect(objects.sightings(.towel) == 0)
    #expect(objects.status(.aed) == .located)
    #expect(objects.worldPoint(.aed) != nil, "an AED stays where it was seen")
}

/// A towel still in view keeps its callout through the wait: it's asked for again before its point
/// runs out, and a same-spot answer counts on from the last one.
@Test func aMovableMaterialIsRefreshedBeforeItExpires() async throws {
    let clock = TestClock()
    let objects = locator(MultiLocator([.towel: middle, .aed: middle]), clock: clock)
    await objects.locate(frozen(), materials: [.towel])
    await objects.locate(frozen(), materials: [.towel])
    #expect(objects.callouts()[.towel] != nil)
    #expect(objects.status(.towel) == .located)

    clock.advance(ObjectLocator.refreshSeconds)
    #expect(objects.status(.towel) == .idle, "due a fresh look")
    #expect(objects.callouts()[.towel] != nil, "and still shown meanwhile")

    clock.advance(5)
    await objects.locate(frozen(), materials: [.towel])
    #expect(objects.sightings(.towel) == 3)
    #expect(objects.status(.towel) == .located)
    clock.advance(ObjectLocator.movableSeconds - 1)
    #expect(objects.callouts()[.towel] != nil, "its time starts again from the refresh")

    // The AED keeps its point and never needs one.
    await objects.locate(frozen(), materials: [.aed])
    clock.advance(ObjectLocator.movableSeconds * 2)
    #expect(objects.status(.aed) == .located)
}

@Test func onlyTheAEDCarries() async throws {
    let objects = locator(FixedLocator(box: middle))
    await objects.locate(frozen(), materials: [.aed, .towel], carries: true)
    #expect(objects.carriedPoint(.aed) != nil)
    #expect(objects.carriedPoint(.towel) == nil)
}

@Test func aCalloutNeedsTwoSightingsAtAboutTheSameSpot() async throws {
    let clock = TestClock()
    let multi = MultiLocator([.towel: middle])
    let objects = locator(multi, clock: clock)
    await objects.locate(frozen(), materials: [.towel])
    #expect(objects.sightings(.towel) == 1)
    #expect(objects.callouts().isEmpty, "one look can be a wrong label")

    await objects.locate(frozen(), materials: [.towel])
    #expect(objects.sightings(.towel) == 2)
    #expect(objects.callouts()[.towel]?.world == objects.worldPoint(.towel))

    // Seen somewhere else: a different towel, or the first answer was wrong. It starts over.
    let far = try #require(NormalizedBox(minX: 0.0, minY: 0.0, maxX: 0.1, maxY: 0.1))
    multi.answer([.towel: far])
    await objects.locate(frozen(), materials: [.towel])
    #expect(objects.sightings(.towel) == 1)
    #expect(objects.callouts().isEmpty)

    // A miss keeps the point and its count until its time runs out.
    multi.answer([.towel: far])
    await objects.locate(frozen(), materials: [.towel])
    multi.answer([:])
    await objects.locate(frozen(), materials: [.towel])
    #expect(objects.status(.towel) == .notFound)
    #expect(objects.sightings(.towel) == 2)
    #expect(objects.callouts()[.towel] != nil)

    clock.advance(ObjectLocator.movableSeconds)
    #expect(objects.callouts().isEmpty)
}

@Test func theAEDIsNeverACallout() async throws {
    let objects = locator(FixedLocator(box: middle))
    await objects.locate(frozen(), materials: [.aed])
    await objects.locate(frozen(), materials: [.aed])
    #expect(objects.sightings(.aed) == 2)
    #expect(objects.callouts().isEmpty, "it has its own arrow")
}

@Test func clearForgetsEveryMaterial() async throws {
    let objects = locator(FixedLocator(box: middle))
    await objects.locate(frozen(), materials: [.aed, .towel, .pillow], carries: true)
    objects.clear()
    for material in Material.allCases {
        #expect(objects.worldPoint(material) == nil)
        #expect(objects.status(material) == .idle)
    }
    #expect(objects.carriedPoint(.aed) == nil)
}

/// The corners lie on the plane through the hit that faces the camera, which here is the wall.
@Test func cornersComeFromTheStoredPoseRays() async throws {
    let objects = locator(FixedLocator(box: middle))
    await objects.locate(frozen(), materials: [.towel])
    #expect(objects.callouts()[.towel] == nil, "seen once")
    await objects.locate(frozen(), materials: [.towel])
    let placed = try #require(objects.callouts()[.towel])
    let corners = try #require(placed.corners)
    #expect(corners.count == 4)
    for (corner, image) in zip(corners, middle.corners) {
        let expected = try #require(await wallAtMinusFour(cameraPose().ray(throughImagePoint: image)))
        #expect(isClose(corner, expected))
    }
}
