import Foundation
import PlumbGeometry
import simd
import Testing
@testable import PlumbReplay

/// What LiDAR is worth: the same frames with the range taken away.
@Suite struct CameraOnlyTests {
    /// The camera-only run differs from the picture slide with LiDAR only in the range. Given the
    /// range LiDAR would have measured, it reads the same depths to within 1 percent.
    @Test func withTheRangeLiDARWouldHaveMeasuredItReadsTheSame() throws {
        let measured = try Replay.run(Traces.standard, settings: .init(method: .imagePlane))
        let range = try #require(measured.rangeMedianM)
        let assumed = try Replay.run(Traces.standard, settings: .init(method: .imagePlane,
                                                                      range: .assumed(metres: range)))
        let ratio = try #require(assumed.summary.depthMedianMM) / #require(measured.summary.depthMedianMM)
        #expect(abs(ratio - 1) < 0.01, "\(ratio)")
        #expect(assumed.summary.count == measured.summary.count)
    }

    /// Without LiDAR the distance is a guess, and every depth is off by the ratio of guess to truth.
    /// Hands 0.6 m away and a guess of 1 m: every push reads about two thirds deeper. Stated
    /// tolerance: the ratio within 3 percent of guess over measured range.
    @Test func aWrongGuessAtTheDistanceScalesEveryDepth() throws {
        let measured = try Replay.run(Traces.nearer, settings: .init(method: .imagePlane))
        let assumed = try Replay.run(Traces.nearer, settings: .init(method: .imagePlane,
                                                                    range: .assumed(metres: 1)))
        let ratio = try #require(assumed.summary.depthMedianMM) / #require(measured.summary.depthMedianMM)
        let expected = 1 / (try #require(measured.rangeMedianM))
        #expect(abs(ratio / expected - 1) < 0.03, "\(ratio) against \(expected)")
        // The rhythm needs no distance at all.
        #expect(abs(try #require(assumed.summary.ratePerMin) - #require(measured.summary.ratePerMin)) < 0.5)
    }

    /// Along the line of sight the height is the LiDAR range, so there is no camera-only version of it.
    @Test func alongTheLineOfSightCannotRunWithoutTheRange() {
        #expect(throws: ReplayFailure.alongRayNeedsRange) {
            try Replay.run(Traces.standard, settings: .init(method: .alongRay, range: .assumed(metres: 1)))
        }
    }

    /// A stripped frame keeps the picture, the pose and the hands' pixel, and carries no depth but
    /// a flat patch at the assumed distance along the line of sight through the hands.
    @Test func aStrippedFrameKeepsThePictureAndLosesEveryDepth() throws {
        let original = try #require(Traces.standard.frames.dropFirst(100).first)
        let stripped = CameraOnly.frame(original, assumedRangeM: 1.2)
        #expect(stripped.reference == nil && stripped.referenceU == nil && stripped.referenceV == nil)
        #expect(stripped.handsLuma == original.handsLuma)
        #expect(stripped.pose == original.pose && stripped.handsU == original.handsU && stripped.t == original.t)
        let reading = try #require(stripped.hands?.nearestSurface())
        #expect(reading.spreadM == 0 && reading.validFraction == 1)
        let point = Projection.unproject(u: stripped.handsU, v: stripped.handsV, depthM: reading.depthM,
                                         intrinsics: stripped.intrinsics, pose: stripped.pose)
        #expect(abs(simd_distance(point, stripped.pose.position) - 1.2) < 1e-5)
    }
}
