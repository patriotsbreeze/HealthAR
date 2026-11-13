import Foundation
import Testing
import PlumbContracts
@testable import PlumbGeometry

/// The still reference patch (drift, noise floor) and the quality figure.
@Suite struct ReferenceAndQualityTests {
    // MARK: - Drift

    /// The reported camera height creeps by 10 mm over ten seconds while the hands stroke 50 mm.
    private func driftingScene(showsReference: Bool) -> SyntheticScene {
        SyntheticScene(tiltDownDegrees: 30, poseDriftMMPerS: 1, showsReference: showsReference)
    }

    @Test func aReferencePatchCancelsSlowCameraDrift() {
        let truth = Session.strokes(seconds: 10)
        let with = EstimatorRun(.alongRay, frames: driftingScene(showsReference: true).frames(following: truth))
        #expect(abs(with.peakToTroughMM - Session.strokeDepthMM) < 4, "measured \(with.peakToTroughMM) mm")
        #expect(with.worstErrorMM(against: truth) < 4)
    }

    @Test func withoutAReferenceTheDriftShowsInTheHeights() {
        let truth = Session.strokes(seconds: 10)
        let without = EstimatorRun(.alongRay, frames: driftingScene(showsReference: false).frames(following: truth))
        #expect(abs(without.peakToTroughMM - Session.strokeDepthMM) > 4, "measured \(without.peakToTroughMM) mm")
        #expect(without.estimator.referenceNoiseMM == nil)
    }

    @Test func imagePlaneDoesNotSeePoseDriftAtAll() {
        let truth = Session.strokes(seconds: 10)
        let run = EstimatorRun(.imagePlane, frames: driftingScene(showsReference: false).frames(following: truth))
        #expect(abs(run.peakToTroughMM - Session.strokeDepthMM) < 4, "measured \(run.peakToTroughMM) mm")
    }

    @Test func aReferenceThatComesAndGoesDoesNotStepTheHeights() {
        let truth = Session.still(seconds: 8)
        var frames = driftingScene(showsReference: true).frames(following: truth)
        // The reference is out of view from 3 s to 5 s.
        for index in 180..<300 {
            frames[index].reference = nil
            frames[index].referenceU = nil
            frames[index].referenceV = nil
        }
        let run = EstimatorRun(.alongRay, frames: frames)
        let steps = zip(run.heights, run.heights.dropFirst()).map { abs($1 - $0) }
        #expect((steps.max() ?? .infinity) < 1.5)
        // While it is away the drift runs on unchecked, and it is taken off again once it is back.
        #expect(run.peakToTroughMM < 4.5)
    }

    @Test func aReferenceThatTurnsIntoSomethingElseIsNotMistakenForDrift() throws {
        let truth = Session.strokes(seconds: 6)
        let scene = SyntheticScene(tiltDownDegrees: 30)
        var frames = scene.frames(following: truth)
        // From 3 s on, something 8 cm nearer covers the reference patch: its height reads 4 cm higher.
        for index in 180..<frames.count {
            let patch = try #require(frames[index].reference)
            frames[index].reference?.depthsM = patch.depthsM.map { $0 - 0.08 }
        }
        let run = EstimatorRun(.alongRay, frames: frames)
        #expect(abs(run.peakToTroughMM - Session.strokeDepthMM) < 6, "measured \(run.peakToTroughMM) mm")
    }

    // MARK: - Noise floor

    @Test(arguments: HeightEstimator.Method.allCases)
    func referenceNoiseIsCloseToTheInjectedNoise(method: HeightEstimator.Method) throws {
        // Jitter in the reported camera height is exactly how much a still patch appears to move.
        let frames = SyntheticScene(poseJitterMM: 2).frames(following: Session.strokes(seconds: 3))
        let run = EstimatorRun(method, frames: frames)
        let noise = try #require(run.estimator.referenceNoiseMM)
        #expect(abs(noise - 2) < 0.4, "reported \(noise) mm")
    }

    @Test func referenceNoiseIsSmallWhenTheCameraIsSteady() throws {
        var estimator = HeightEstimator(method: .alongRay)
        let frames = SyntheticScene(tiltDownDegrees: 30).frames(following: Session.strokes(seconds: 3))
        _ = estimator.ingest(frames[0])
        #expect(estimator.referenceNoiseMM == nil)
        for frame in frames.dropFirst() { _ = estimator.ingest(frame) }
        // Only depth noise on the patch is left: 3 mm a sample, averaged over a 16x16 patch.
        #expect(try #require(estimator.referenceNoiseMM) < 0.5)
    }

    @Test func theFastShareAlsoCancelsShakeTheTwoPatchesHaveInCommon() {
        let truth = Session.still(seconds: 4)
        let frames = SyntheticScene(poseJitterMM: 2).frames(following: truth)
        let slowOnly = EstimatorRun(.alongRay, frames: frames)
        let fullBand = EstimatorRun(.alongRay, frames: frames, config: .init(referenceFastShare: 1))
        // Skip the first reading or two, taken before the reference's level is believed.
        let shaky = Stats.standardDeviation(Array(slowOnly.heights.dropFirst(20))) ?? 0
        let steady = Stats.standardDeviation(Array(fullBand.heights.dropFirst(20))) ?? .infinity
        #expect(shaky > 1.5)
        #expect(steady < 0.6)
    }

    // MARK: - Quality

    @Test(arguments: HeightEstimator.Method.allCases)
    func aCleanSceneIsFullyTrusted(method: HeightEstimator.Method) {
        let run = EstimatorRun(method, frames: SyntheticScene().frames(following: Session.strokes(seconds: 2)))
        #expect(run.meanQuality > 0.85, "mean quality \(run.meanQuality)")
        #expect(run.samples.allSatisfy { (0...1).contains($0.quality) })
    }

    @Test(arguments: HeightEstimator.Method.allCases)
    func qualityFallsWhenHalfTheHandsPatchIsLowConfidence(method: HeightEstimator.Method) {
        let truth = Session.strokes(seconds: 2)
        let clean = EstimatorRun(method, frames: SyntheticScene().frames(following: truth))
        let halved = EstimatorRun(method, frames: SyntheticScene(halfLowConfidence: true).frames(following: truth))
        #expect(halved.samples.count == truth.count)
        #expect(halved.meanQuality < clean.meanQuality - 0.2,
                "clean \(clean.meanQuality), halved \(halved.meanQuality)")
    }

    @Test(arguments: HeightEstimator.Method.allCases)
    func qualityIsCappedWhenTrackingIsNotNormal(method: HeightEstimator.Method) {
        let truth = Session.strokes(seconds: 2)
        let lost = EstimatorRun(method, frames: SyntheticScene(trackingNormal: false).frames(following: truth))
        #expect(lost.samples.count == truth.count)
        #expect(lost.samples.allSatisfy { $0.quality <= 0.3 })
        #expect(lost.meanQuality > 0.2)
    }

    @Test func alongRayTrustsItselfALittleLessWithoutAReference() {
        let truth = Session.strokes(seconds: 2)
        let with = EstimatorRun(.alongRay, frames: SyntheticScene().frames(following: truth))
        let without = EstimatorRun(.alongRay, frames: SyntheticScene(showsReference: false).frames(following: truth))
        #expect(abs(without.meanQuality - 0.9 * with.meanQuality) < 0.02)
    }

    @Test func qualityFallsWhenTheHandsAreNotOneSurface() throws {
        // Smear the hands patch's depths over 40 cm, as hands, arms and torso merged into one group would.
        var frames = SyntheticScene().frames(following: Session.still(seconds: 0.5))
        for index in frames.indices {
            let patch = try #require(frames[index].hands)
            frames[index].hands?.depthsM = patch.depthsM.indices.map { 0.8 + 0.4 * Float($0) / Float(patch.depthsM.count) }
        }
        let run = EstimatorRun(.alongRay, frames: frames)
        #expect(run.samples.count == frames.count)
        #expect(run.meanQuality < 0.3, "mean quality \(run.meanQuality)")
    }
}
