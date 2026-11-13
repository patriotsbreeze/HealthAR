import Foundation
import PlumbGeometry
import simd
import Testing
@testable import PlumbCapture

struct HandsFinderTests {
    let config = CaptureConfig()
    let camera = TestScene.level

    /// Someone compressing, seen from the side by a level camera: wrists together at v = 800,
    /// elbows above them, shoulders higher still. `shift` slides the whole body across the image.
    func rescuer(shift: Double = 0) -> BodyJoints {
        BodyJoints(leftWrist: SIMD2(900 + shift, 800), rightWrist: SIMD2(960 + shift, 800),
                   leftElbow: SIMD2(880 + shift, 700), rightElbow: SIMD2(980 + shift, 700),
                   leftShoulder: SIMD2(850 + shift, 500), rightShoulder: SIMD2(1010 + shift, 500))
    }

    // MARK: The wrist-to-hands rule

    @Test func handsSitPastTheWristsAlongTheForearms() throws {
        // Forearms (20, 100) and (-20, 100) average to (0, 100); 0.35 of it past the midpoint (930, 800).
        let hands = try #require(HandsFinder.handsPixel(rescuer(), beyondWristShare: 0.35))
        #expect(abs(hands.x - 930) < 1e-9 && abs(hands.y - 835) < 1e-9)
    }

    @Test func oneElbowIsEnoughAndNoElbowMeansTheMidpoint() throws {
        var body = rescuer()
        body.rightElbow = nil
        let oneArm = try #require(HandsFinder.handsPixel(body, beyondWristShare: 0.5))
        #expect(abs(oneArm.x - 940) < 1e-9 && abs(oneArm.y - 850) < 1e-9)
        body.leftElbow = nil
        #expect(HandsFinder.handsPixel(body, beyondWristShare: 0.5) == SIMD2(930, 800))
    }

    @Test func noHandsWithoutBothWrists() {
        var body = rescuer()
        body.leftWrist = nil
        #expect(HandsFinder.handsPixel(body, beyondWristShare: 0.35) == nil)
    }

    // MARK: Below the shoulders

    @Test func wristsBelowShouldersFollowsWorldUpNotTheImage() {
        let body = rescuer()
        #expect(HandsFinder.wristsBelowShoulders(body, upDirection: SIMD2(0, -1)))
        // Camera upside down: world-up now points down the image, so the same pixels mean hands raised.
        #expect(!HandsFinder.wristsBelowShoulders(body, upDirection: SIMD2(0, 1)))
        var noShoulders = body
        noShoulders.leftShoulder = nil
        noShoulders.rightShoulder = nil
        #expect(!HandsFinder.wristsBelowShoulders(noShoulders, upDirection: SIMD2(0, -1)))
    }

    // MARK: Picking by range

    @Test func picksTheNearestWithinRange() {
        #expect(HandsFinder.nearest([1.4, 0.9, 1.1], within: 2) == 1)
        #expect(HandsFinder.nearest([2.5, 1.9], within: 2) == 1)
        #expect(HandsFinder.nearest([2.01, 3], within: 2) == nil)
        #expect(HandsFinder.nearest([], within: 2) == nil)
    }

    // MARK: The whole rule set

    @Test func seedsAtTheNearestSurfaceUnderTheHands() throws {
        // A chest 1.1 m away with the hands 0.95 m away covering the rows around the hands pixel.
        let handsRow = DepthCells(intrinsics: TestScene.intrinsics, mapWidth: 256, mapHeight: 192).cell(u: 930, v: 835).row
        let depth = TestScene.depthMap { _, row in abs(row - handsRow) <= 1 ? 0.95 : 1.1 }
        let found = try #require(HandsFinder.find([rescuer()], depth: depth, camera: camera, config: config))
        let expected = Projection.unproject(u: 930, v: 835, depthM: 0.95, intrinsics: camera.intrinsics, pose: camera.pose)
        #expect(simd_distance(found, expected) < 1e-4)
    }

    @Test func ignoresABystanderBeyondTwoMetres() {
        let depth = TestScene.depthMap { _, _ in 2.5 }
        #expect(HandsFinder.find([rescuer()], depth: depth, camera: camera, config: config) == nil)
    }

    @Test func choosesTheNearerOfTwoPeople() throws {
        // Left half of the image 1.6 m away, right half 0.9 m.
        let depth = TestScene.depthMap { column, _ in column < 128 ? 1.6 : 0.9 }
        let far = rescuer(shift: -600), near = rescuer(shift: 300)
        let found = try #require(HandsFinder.find([far, near], depth: depth, camera: camera, config: config))
        let expected = Projection.unproject(u: 1230, v: 835, depthM: 0.9, intrinsics: camera.intrinsics, pose: camera.pose)
        #expect(simd_distance(found, expected) < 1e-4)
    }

    @Test func refusesWristsTooFarApart() {
        var apart = rescuer()
        // 400 pixels at a metre is about 28 cm.
        apart.rightWrist = SIMD2(1300, 800)
        let depth = TestScene.depthMap { _, _ in 1.0 }
        #expect(HandsFinder.find([apart], depth: depth, camera: camera, config: config) == nil)
    }

    @Test func refusesHandsAboveTheShoulders() {
        var raised = rescuer()
        raised.leftShoulder = SIMD2(850, 1000)
        raised.rightShoulder = SIMD2(1010, 1000)
        let depth = TestScene.depthMap { _, _ in 1.0 }
        #expect(HandsFinder.find([raised], depth: depth, camera: camera, config: config) == nil)
    }

    @Test func refusesWristsWithNoTrustedDepth() {
        let unsure = TestScene.depthMap(confidence: 0) { _, _ in 1.0 }
        #expect(HandsFinder.find([rescuer()], depth: unsure, camera: camera, config: config) == nil)
    }
}
