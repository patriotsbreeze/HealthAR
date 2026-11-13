import CoreGraphics
import Foundation
import PlumbGeometry
import simd
import Testing
@testable import PlumbCapture

struct WorldBoxTests {
    let hands = WorldBox(centre: SIMD3(0, 0, -1), widthM: 0.14, heightM: 0.24)

    @Test func sidewaysIsLevelAndPointsToTheCameraRight() throws {
        let level = try #require(WorldBox.sideways(of: TestScene.level.pose))
        #expect(simd_distance(level, SIMD3(1, 0, 0)) < 1e-6)
        let tilted = try #require(WorldBox.sideways(of: .aimed(from: .zero, tiltDownRadians: 0.7, rollRadians: 0.2)))
        #expect(abs(tilted.y) < 1e-9 && abs(simd_length(tilted) - 1) < 1e-9)
    }

    @Test func boxAtAMetreSpansItsSizeTimesTheFocalLength() throws {
        let bounds = try #require(hands.imageBounds(intrinsics: TestScene.intrinsics, pose: TestScene.level.pose))
        #expect(abs(bounds.width - 0.14 * 1450) < 1e-6)
        #expect(abs(bounds.height - 0.24 * 1450) < 1e-6)
        #expect(abs(bounds.midX - 960) < 1e-6 && abs(bounds.midY - 720) < 1e-6)
    }

    @Test func normalisedBoundsAreShareOfTheImage() throws {
        let share = try #require(hands.normalizedBounds(intrinsics: TestScene.intrinsics, pose: TestScene.level.pose))
        #expect(abs(share.midX - 0.5) < 1e-9 && abs(share.midY - 0.5) < 1e-9)
        #expect(abs(share.width - 0.14 * 1450 / 1920) < 1e-9)
    }

    @Test func boxBehindTheCameraHasNoBounds() {
        let behind = WorldBox(centre: SIMD3(0, 0, 1), widthM: 0.14, heightM: 0.24)
        #expect(behind.imageBounds(intrinsics: TestScene.intrinsics, pose: TestScene.level.pose) == nil)
    }

    @Test func handsPatchIsSizedFromTheBoxAndRange() throws {
        let pipeline = FramePipeline(config: CaptureConfig(), method: .alongRay, depthSupported: true)
        let depth = TestScene.depthMap { _, _ in 1 }
        let atOneMetre = try #require(pipeline.patch(of: hands, in: depth, camera: TestScene.level,
                                                     maxColumns: 32, maxRows: 48))
        #expect(atOneMetre.width == 28 && atOneMetre.height == 47)
        let near = WorldBox(centre: SIMD3(0, 0, -0.5), widthM: 0.14, heightM: 0.24)
        let capped = try #require(pipeline.patch(of: near, in: depth, camera: TestScene.level, maxColumns: 32, maxRows: 48))
        #expect(capped.width == 32 && capped.height == 48)
        let far = WorldBox(centre: SIMD3(0, 0, -6), widthM: 0.14, heightM: 0.24)
        let small = try #require(pipeline.patch(of: far, in: depth, camera: TestScene.level, maxColumns: 32, maxRows: 48))
        #expect(small.width == 5 && small.height == 8)
    }
}
