import Foundation
import Testing
import PlumbContracts
@testable import PlumbGeometry

/// Both methods against the rendered scene at 1 m. The estimator's output is checked as it comes,
/// with no smoothing: peak-to-trough of the height signal against the true 50 mm stroke.
@Suite struct HeightEstimatorTests {
    static let methods = HeightEstimator.Method.allCases

    @Test(arguments: methods)
    func aLevelCameraMeasuresTheStrokeWithinFourMillimetres(method: HeightEstimator.Method) {
        let truth = Session.strokes()
        let run = EstimatorRun(method, frames: SyntheticScene().frames(following: truth))
        #expect(run.samples.count == truth.count)
        #expect(abs(run.peakToTroughMM - Session.strokeDepthMM) < 4, "measured \(run.peakToTroughMM) mm")
        #expect(abs(run.gain(against: truth) - 1) < 0.05)
        #expect(run.worstErrorMM(against: truth) < 4)
    }

    @Test(arguments: methods)
    func aTiltedAndRolledCameraMeasuresTheStrokeWithinSixMillimetres(method: HeightEstimator.Method) {
        let truth = Session.strokes()
        let scene = SyntheticScene(tiltDownDegrees: 30, rollDegrees: 10)
        let run = EstimatorRun(method, frames: scene.frames(following: truth))
        #expect(run.samples.count == truth.count)
        #expect(abs(run.peakToTroughMM - Session.strokeDepthMM) < 6, "measured \(run.peakToTroughMM) mm")
        #expect(abs(run.gain(against: truth) - 1) < 0.05)
    }

    @Test func alongRayHoldsAtFortyFiveDegreesOfTilt() {
        let truth = Session.strokes()
        let scene = SyntheticScene(tiltDownDegrees: 45)
        let run = EstimatorRun(.alongRay, frames: scene.frames(following: truth))
        #expect(run.samples.count == truth.count)
        #expect(abs(run.peakToTroughMM - Session.strokeDepthMM) < 6, "measured \(run.peakToTroughMM) mm")
        #expect(abs(run.gain(against: truth) - 1) < 0.05)
    }

    @Test(arguments: methods)
    func aPhoneStandingOnItsShortEdgeMeasuresTheStroke(method: HeightEstimator.Method) {
        // A quarter turn about the lens: world-up runs sideways across the image.
        let truth = Session.strokes()
        let scene = SyntheticScene(tiltDownDegrees: 20, rollDegrees: 90)
        let run = EstimatorRun(method, frames: scene.frames(following: truth))
        #expect(run.samples.count == truth.count)
        #expect(abs(run.peakToTroughMM - Session.strokeDepthMM) < 6, "measured \(run.peakToTroughMM) mm")
        #expect(abs(run.gain(against: truth) - 1) < 0.05)
    }

    /// How a camera is propped, in degrees.
    struct Propping: Sendable, CustomTestStringConvertible {
        var tilt: Double
        var roll: Double
        var testDescription: String { "tilt \(tilt), roll \(roll)" }

        static let all = [Propping(tilt: 0, roll: 0), Propping(tilt: 30, roll: 10), Propping(tilt: 45, roll: -25),
                          Propping(tilt: 20, roll: 90), Propping(tilt: 15, roll: 180), Propping(tilt: 35, roll: -90)]
    }

    @Test(arguments: methods, Propping.all)
    func heightsRiseWhenTheHandsRise(method: HeightEstimator.Method, camera: Propping) {
        let truth = Session.lift(byMM: 30)
        let scene = SyntheticScene(tiltDownDegrees: camera.tilt, rollDegrees: camera.roll)
        let run = EstimatorRun(method, frames: scene.frames(following: truth))
        #expect(run.samples.count == truth.count)
        let before = run.heights.prefix(20).reduce(0, +) / 20
        let after = run.heights.suffix(20).reduce(0, +) / 20
        #expect(abs(after - before - 30) < 2, "rose \(after - before) mm")
    }

    @Test(arguments: methods)
    func sampleTimesAreTheFrameTimes(method: HeightEstimator.Method) {
        let truth = Session.strokes(seconds: 1)
        let run = EstimatorRun(method, frames: SyntheticScene().frames(following: truth))
        #expect(run.samples.map(\.t) == truth.map(\.t))
    }

    // MARK: - Range and missing data

    @Test(arguments: methods, [Propping(tilt: 0, roll: 0), Propping(tilt: 30, roll: 10), Propping(tilt: 45, roll: 0)])
    func theRangeIsWithinTwoCentimetresOfTheTruthOnEveryFrame(method: HeightEstimator.Method, camera: Propping) throws {
        let truth = Session.strokes(seconds: 3)
        let scene = SyntheticScene(tiltDownDegrees: camera.tilt, rollDegrees: camera.roll)
        var estimator = HeightEstimator(method: method)
        #expect(estimator.rangeM == nil)
        var worst = 0.0
        for (frame, height) in zip(scene.frames(following: truth), truth) {
            _ = estimator.ingest(frame)
            let range = try #require(estimator.rangeM)
            worst = max(worst, abs(range - scene.trueRangeM(handsHeightM: height.heightMM / 1000)))
        }
        // The hands' range from a tilted camera swings by centimetres with each stroke; the
        // reported range follows it because it is tied to the floor plan, not to a median range.
        #expect(worst < 0.02, "worst error \(worst) m")
    }

    @Test(arguments: methods)
    func theRangeFollowsTheCameraFartherAway(method: HeightEstimator.Method) throws {
        let far = SyntheticScene(tiltDownDegrees: 30, rollDegrees: 10, rangeM: 1.6)
        let run = EstimatorRun(method, frames: far.frames(following: Session.still(seconds: 1)))
        #expect(abs(try #require(run.estimator.rangeM) - far.trueRangeM()) < 0.02)
    }

    @Test(arguments: methods)
    func aStrokeThatDriftsSidewaysIsStillMeasured(method: HeightEstimator.Method) {
        // Six millimetres of sideways travel at the bottom of a 50 mm stroke, level and tilted.
        let truth = Session.strokes()
        for tilt in [0.0, 30] {
            let scene = SyntheticScene(tiltDownDegrees: tilt, sidewaysSlope: 0.12)
            let run = EstimatorRun(method, frames: scene.frames(following: truth))
            #expect(run.samples.count == truth.count)
            #expect(abs(run.peakToTroughMM - Session.strokeDepthMM) < 6, "tilt \(tilt): \(run.peakToTroughMM) mm")
            #expect(run.samples.allSatisfy { $0.quality > 0.3 })
        }
    }

    @Test func alongRayGivesNothingWithoutAReadableHandsPatch() {
        var frames = SyntheticScene().frames(following: Session.still(seconds: 0.2))
        frames[3].hands = nil
        frames[4].hands?.confidence = [UInt8](repeating: 0, count: 576)
        let run = EstimatorRun(.alongRay, frames: frames)
        #expect(run.outputs[2] != nil)
        #expect(run.outputs[3] == nil)
        #expect(run.outputs[4] == nil)
        #expect(run.outputs[5] != nil)
    }

    @Test func imagePlaneGivesNothingWithoutAPictureOrARange() {
        var frames = SyntheticScene().frames(following: Session.still(seconds: 0.2))
        frames[0].hands = nil
        frames[1].hands = nil
        frames[5].handsLuma = nil
        let run = EstimatorRun(.imagePlane, frames: frames)
        // No range yet for the first two frames, so there is no ruler to measure with.
        #expect(run.outputs[0] == nil)
        #expect(run.outputs[1] == nil)
        #expect(run.outputs[2]?.heightMM == 0)
        #expect(run.outputs[5] == nil)
        #expect(run.outputs[6] != nil)
    }

    @Test func imagePlaneKeepsMeasuringThroughShortGapsInTheDepth() {
        let truth = Session.strokes(seconds: 3)
        var frames = SyntheticScene().frames(following: truth)
        // The ruler remembers the range for a second, so a depth dropout of a third of one is harmless.
        for index in 100..<120 { frames[index].hands = nil }
        let run = EstimatorRun(.imagePlane, frames: frames)
        #expect(run.samples.count == truth.count)
        #expect(abs(run.peakToTroughMM - Session.strokeDepthMM) < 4)
    }

    // MARK: - Key frames

    @Test func imagePlaneTakesANewKeyFrameWhenThePictureChanges() throws {
        let truth = Session.strokes(seconds: 3)
        var frames = SyntheticScene().frames(following: truth)
        // Mid-stroke, at frame 108, the patch starts showing something unrelated: the same scene
        // painted differently.
        let change = 108
        let other = SyntheticScene(textureSeed: 400).frames(following: truth)
        for index in change..<frames.count { frames[index].handsLuma = other[index].handsLuma }

        let config = HeightEstimator.Config()
        let run = EstimatorRun(.imagePlane, frames: frames, config: config)
        let lastGood = try #require(run.outputs[change - 1])
        let changed = try #require(run.outputs[change])
        #expect(lastGood.quality > 0.5)
        #expect(changed.quality <= config.rekeyQuality)
        // The height holds where it was; it does not jump back to the key frame's zero.
        #expect(changed.heightMM == lastGood.heightMM)
        #expect(lastGood.heightMM < -20)
        // And measuring carries on from there against the new key frame.
        let later = try #require(run.outputs[change + 5])
        #expect(later.quality > 0.5)
        #expect(later.heightMM > lastGood.heightMM)
    }

    @Test func imagePlaneHoldsItsHeightWhenTheGridIsLaidOutAgain() throws {
        let truth = Session.strokes(seconds: 3)
        var frames = SyntheticScene().frames(following: truth)
        // From frame 120 the capture side re-cuts the patch with another row spacing.
        for index in 120..<frames.count { frames[index].handsLuma?.pitchPx *= 1.25 }

        let run = EstimatorRun(.imagePlane, frames: frames)
        let lastGood = try #require(run.outputs[119])
        let relaid = try #require(run.outputs[120])
        #expect(relaid.heightMM == lastGood.heightMM)
        #expect(relaid.quality <= HeightEstimator.Config().rekeyQuality)
        #expect(try #require(run.outputs[121]).quality > 0.5)
    }

    // MARK: - A luma grid that moves

    @Test func aGridLaidSomewhereElseDoesNotMoveTheHeightsWhenItsCentreIsReported() {
        let truth = Session.strokes(seconds: 3)
        // Two seconds in, the capture side moves the grid 15 pixels (about a centimetre) up the image.
        let scene = SyntheticScene(lumaGrid: .hops(px: 15, afterS: 2))
        let run = EstimatorRun(.imagePlane, frames: scene.frames(following: truth))
        #expect(run.samples.count == truth.count)
        #expect(run.worstErrorMM(against: truth) < 2, "worst \(run.worstErrorMM(against: truth)) mm")
        #expect(abs(run.peakToTroughMM - Session.strokeDepthMM) < 4)
        #expect(run.samples.allSatisfy { $0.quality > 0.5 })
    }

    @Test func theSameMoveReadsAsHandMotionWhenTheCentreIsNotReported() {
        let truth = Session.strokes(seconds: 3)
        let scene = SyntheticScene(lumaGrid: .hops(px: 15, afterS: 2), reportsLumaCentre: false)
        let run = EstimatorRun(.imagePlane, frames: scene.frames(following: truth))
        // 15 px at 1 m is about 10 mm of height that never happened.
        #expect(run.worstErrorMM(against: truth) > 4)
    }

    @Test func aGridThatFollowsTheHandsMeasuresTheSameStroke() {
        let truth = Session.strokes(seconds: 3)
        for tilt in [0.0, 30] {
            let scene = SyntheticScene(tiltDownDegrees: tilt, lumaGrid: .followsHands)
            let run = EstimatorRun(.imagePlane, frames: scene.frames(following: truth))
            #expect(run.samples.count == truth.count)
            #expect(abs(run.peakToTroughMM - Session.strokeDepthMM) < 4, "tilt \(tilt): \(run.peakToTroughMM) mm")
            #expect(run.worstErrorMM(against: truth) < 2, "tilt \(tilt): worst \(run.worstErrorMM(against: truth)) mm")
        }
    }

    // MARK: - Reset

    @Test(arguments: methods)
    func resetForgetsEverything(method: HeightEstimator.Method) {
        let frames = SyntheticScene(tiltDownDegrees: 30).frames(following: Session.strokes(seconds: 2))
        var estimator = HeightEstimator(method: method)
        let first = frames.map { estimator.ingest($0) }
        #expect(estimator.rangeM != nil)
        #expect(estimator.referenceNoiseMM != nil)

        estimator.reset()
        #expect(estimator.rangeM == nil)
        #expect(estimator.referenceNoiseMM == nil)
        #expect(frames.map { estimator.ingest($0) } == first)
    }
}
