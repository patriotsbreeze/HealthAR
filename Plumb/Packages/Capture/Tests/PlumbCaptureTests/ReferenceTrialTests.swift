import Foundation
import PlumbGeometry
import simd
import Testing
@testable import PlumbCapture

struct ReferenceTrialTests {
    @Test func candidatesSitLevelWithTheHandsEitherSide() throws {
        let centre = SIMD3<Double>(0.1, -0.4, -1)
        let pose = CameraPose.aimed(from: SIMD3(0, 0.3, 0), tiltDownRadians: 0.6, rollRadians: 0.1, headingRadians: 0.3)
        let trial = try #require(ReferenceTrial(beside: centre, offsetM: 0.25, pose: pose))
        #expect(trial.candidates.count == 2)
        for point in trial.candidates {
            #expect(abs(point.y - centre.y) < 1e-12)
            #expect(abs(simd_distance(point, centre) - 0.25) < 1e-12)
        }
        // The first is on the camera's left: further left in the image than the hands.
        let intrinsics = TestScene.intrinsics
        let left = try #require(Projection.project(trial.candidates[0], intrinsics: intrinsics, pose: pose))
        let hands = try #require(Projection.project(centre, intrinsics: intrinsics, pose: pose))
        #expect(left.u < hands.u)
    }

    @Test func noCandidatesWhenLookingStraightDown() {
        let down = CameraPose.looking(from: .zero, along: SIMD3(0, -1, 0))
        #expect(ReferenceTrial(beside: SIMD3(0, -1, 0), offsetM: 0.25, pose: down) == nil)
    }

    @Test func keepsTheSteadierSideOnceTheWatchIsOver() {
        let left = SIMD3<Double>(-0.25, 0, -1), right = SIMD3<Double>(0.25, 0, -1)
        var trial = ReferenceTrial(candidates: [left, right])
        var t = 0.0
        var chosen: SIMD3<Double>?
        for frame in 0..<30 {
            trial.observe(1.0 + 0.0005 * Double(frame % 2), candidate: 0, at: t)
            trial.observe(1.0 + 0.02 * Double(frame % 3), candidate: 1, at: t)
            chosen = trial.decide(at: t, durationS: 0.5, minReadings: 8)
            if chosen != nil { break }
            t += 1.0 / 30
        }
        #expect(chosen == left)
        // Not before half a second had passed.
        #expect(t >= 0.5 && t < 0.5 + 1.0 / 30 + 1e-9)
    }

    @Test func aSideWithTooFewReadingsCannotWin() {
        let left = SIMD3<Double>(-0.25, 0, -1), right = SIMD3<Double>(0.25, 0, -1)
        var trial = ReferenceTrial(candidates: [left, right])
        for frame in 0..<20 {
            let t = Double(frame) / 30
            // The left side is perfectly still but only read twice.
            trial.observe(frame < 2 ? 1.0 : nil, candidate: 0, at: t)
            trial.observe(1.0 + 0.01 * Double(frame % 2), candidate: 1, at: t)
        }
        #expect(trial.decide(at: 20.0 / 30, durationS: 0.5, minReadings: 8) == right)
    }

    @Test func startsOverWhenNeitherSideCanBeRead() {
        var trial = ReferenceTrial(candidates: [SIMD3(-0.25, 0, -1), SIMD3(0.25, 0, -1)])
        for frame in 0..<20 {
            trial.observe(nil, candidate: 0, at: Double(frame) / 30)
            trial.observe(nil, candidate: 1, at: Double(frame) / 30)
        }
        #expect(trial.decide(at: 0.7, durationS: 0.5, minReadings: 8) == nil)
        // The watch began again, so a decision needs another half second of readings.
        for frame in 0..<10 {
            let t = 0.8 + Double(frame) / 30
            trial.observe(1.0, candidate: 0, at: t)
            trial.observe(1.0, candidate: 1, at: t)
        }
        #expect(trial.decide(at: 0.8 + 9.0 / 30, durationS: 0.5, minReadings: 8) == nil)
    }
}
