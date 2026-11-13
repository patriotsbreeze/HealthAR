import Foundation
import PlumbContracts
import PlumbGeometry
import simd
import Testing
@testable import PlumbCapture

struct LinePlacementTests {
    let camera = TestScene.propped
    /// Hands 4 cm thick on a chest at floor level, the box seeded on the chest where the camera looks.
    let handsCentre = TestScene.floorAhead
    let restTopM = 0.04

    func place(towardCameraM: Double = 0.04, restTopM: Double? = nil, pose: CameraPose? = nil) -> LinePlacement? {
        LinePlacement.place(handsCentre: handsCentre, restTopM: restTopM ?? self.restTopM, sinkM: 0.05,
                            pose: pose ?? camera.pose, towardCameraM: towardCameraM, maxSlideM: 0.3)
    }

    func pixel(_ point: SIMD3<Double>) throws -> SIMD2<Double> {
        let seen = try #require(Projection.project(point, intrinsics: camera.intrinsics, pose: camera.pose))
        return SIMD2(seen.u, seen.v)
    }

    @Test func theRestPointIsOnTheLineOfSightThroughTheHands() throws {
        let rest = LinePlacement.restPoint(handsCentre: handsCentre, heightM: restTopM,
                                           camera: camera.pose.position, maxSlideM: 0.3)
        #expect(abs(rest.y - restTopM) < 1e-12)
        #expect(simd_distance(try pixel(rest), try pixel(handsCentre)) < 1e-6)
        // Higher on a line of sight that looks down is nearer the camera.
        #expect(rest.z > handsCentre.z)
    }

    @Test func thePictureShowsTheLineWhereTheTargetIs() throws {
        let line = try #require(place())
        let rest = LinePlacement.restPoint(handsCentre: handsCentre, heightM: restTopM,
                                           camera: camera.pose.position, maxSlideM: 0.3)
        let target = rest - SIMD3(0, 0.05, 0)
        #expect(simd_distance(try pixel(line.centre), try pixel(target)) < 1e-6)
        // Pulled 4 cm toward the camera, so it stands in front of the hands.
        #expect(abs(simd_distance(line.centre, target) - 0.04) < 1e-9)
        #expect(simd_distance(line.centre, camera.pose.position) < simd_distance(target, camera.pose.position))
    }

    @Test func withNoPullTheLineIsAtTheTargetHeight() throws {
        let line = try #require(place(towardCameraM: 0))
        #expect(abs(line.centre.y - (restTopM - 0.05)) < 1e-12)
    }

    @Test func theLineRunsLevelAndSquareToTheCamera() throws {
        let line = try #require(place())
        #expect(abs(line.along.y) < 1e-12 && abs(simd_length(line.along) - 1) < 1e-12)
        let sight = line.centre - camera.pose.position
        #expect(abs(simd_dot(line.along, SIMD3(sight.x, 0, sight.z))) < 1e-9)
        // To the camera's right: here, world +x.
        #expect(line.along.x > 0.999)
        let turned = line.rotation.act(SIMD3<Float>(1, 0, 0))
        #expect(simd_distance(turned, SIMD3<Float>(line.along)) < 1e-6)
    }

    @Test func aTurnedCameraTurnsTheLine() throws {
        let turned = CameraPose.aimed(from: SIMD3(0, 0.6, 0), tiltDownRadians: .pi / 6, headingRadians: 0.8)
        let line = try #require(place(pose: turned))
        let along = line.rotation.act(SIMD3<Float>(1, 0, 0))
        #expect(simd_distance(along, SIMD3<Float>(line.along)) < 1e-6)
        #expect(abs(line.along.x - cos(0.8)) < 1e-6 && abs(line.along.z + sin(0.8)) < 1e-6)
    }

    @Test func aLevelLineOfSightStandsTheLineAboveTheCentre() {
        let rest = LinePlacement.restPoint(handsCentre: SIMD3(0, 0, -1), heightM: 0.03, camera: .zero, maxSlideM: 0.3)
        #expect(rest == SIMD3(0, 0.03, -1))
    }

    @Test func aRestHeightFarFromTheCentreStandsTheLineAboveIt() {
        // Half a metre above the chest is no top of the hands; the slide along the sight is too long.
        let rest = LinePlacement.restPoint(handsCentre: handsCentre, heightM: 0.5, camera: camera.pose.position,
                                           maxSlideM: 0.3)
        #expect(rest == SIMD3(handsCentre.x, 0.5, handsCentre.z))
    }

    @Test func noLineForACameraLookingStraightDown() {
        let down = CameraPose.looking(from: SIMD3(0, 1, 0), along: SIMD3(0, -1, 0))
        #expect(place(pose: down) == nil)
    }
}

struct DashPatternTests {
    @Test func solidIsOneWholePiece() {
        #expect(DashPattern.solid(lengthM: 0.25) == [DashPattern.Piece(centre: 0, length: 0.25)])
    }

    @Test func dashesAreEvenCentredAndInsideTheBar() {
        let dashes = DashPattern.dashed(lengthM: 0.25, dashM: 0.02, gapM: 0.015)
        #expect(dashes.count == 7)
        #expect(dashes.allSatisfy { $0.length == 0.02 })
        #expect(abs(dashes.map(\.centre).reduce(0, +)) < 1e-12)
        #expect(zip(dashes, dashes.dropFirst()).allSatisfy { abs($1.centre - $0.centre - 0.035) < 1e-12 })
        #expect(dashes.allSatisfy { abs($0.centre) + $0.length / 2 <= 0.125 + 1e-12 })
    }

    @Test func aBarTooShortForTwoDashesStaysWhole() {
        #expect(DashPattern.dashed(lengthM: 0.04, dashM: 0.02, gapM: 0.015) == DashPattern.solid(lengthM: 0.04))
        #expect(DashPattern.dashed(lengthM: 0, dashM: 0.02, gapM: 0.015).isEmpty)
    }
}

struct GuideStateTests {
    @Test func theLineFollowsTheLockOnlyWhileCompressing() {
        for lock in LockState.allCases {
            let still = GuideState(lock: lock, compressing: false, visible: true)
            #expect(still.lineStyle == nil)
            let hidden = GuideState(lock: lock, compressing: true, visible: false)
            #expect(hidden.lineStyle == nil && !hidden.showsRing)
        }
        #expect(GuideState(lock: .locked, compressing: true, visible: true).lineStyle == .solid)
        #expect(GuideState(lock: .estimating, compressing: true, visible: true).lineStyle == .dashed)
        #expect(GuideState(lock: .rateOnly, compressing: true, visible: true).lineStyle == nil)
        #expect(GuideState(lock: .lost, compressing: true, visible: true).lineStyle == nil)
    }

    @Test func theRingShowsBeforeAndDuringCompressions() {
        #expect(GuideState.initial.showsRing && GuideState.initial.lineStyle == nil)
        #expect(GuideState(lock: .locked, compressing: true, visible: true).showsRing)
    }
}
