import Foundation
import PlumbContracts
import Testing
@testable import PlumbReplay

/// A gain is fitted on one recording and only ever scored on another.
@Suite struct GainTests {
    private let cameraOnly = ReplaySettings(method: .imagePlane, range: .assumed(metres: 1))

    /// The gain is exactly what puts the fitted recording's median locked depth on the truth.
    @Test func theFitPutsTheMedianOnTheTruth() throws {
        let result = try Replay.run(Traces.standard, settings: cameraOnly)
        let fitted = try GainFit.fit(result, truthDepthMM: 50)
        let median = try #require(result.summary.depthMedianMM)
        #expect(abs(fitted.gain.value - 50 / median) < 1e-12)
        #expect(fitted.gain.fittedOn == Traces.standard.fingerprint)
        #expect(fitted.strokeCount == result.summary.lockedCount)
        #expect(fitted.medianDepthMM == median)
    }

    /// Fitted on one recording, scored on another made the same way at the same distance: the
    /// camera-only depth lands on the truth. Stated tolerance: median error and bias within 1.5 mm.
    @Test func aGainHoldsOnAnotherRecordingAtTheSameDistance() throws {
        let fitted = try GainFit.fit(Replay.run(Traces.standard, settings: cameraOnly), truthDepthMM: 50)
        var settings = cameraOnly
        settings.gain = fitted.gain
        let report = try Replay.run(Traces.sameDistance, settings: settings).compared(with: Truth(depthMM: 50))
        let depth = try #require(report.depthLocked)
        #expect(depth.medianAbsoluteError <= 1.5 && abs(depth.bias) <= 1.5, "\(depth)")
    }

    /// The honest comparison. A camera-only gain fitted at 0.9 m reads the same 50 mm at 0.6 m about
    /// 45 percent deep, since the picture of a nearer push slides further. Along the line of sight the
    /// LiDAR range carries the scale, and no gain is needed at either distance.
    @Test func aCameraOnlyGainDoesNotTravelToAnotherDistanceButLiDARNeedsNone() throws {
        let fitted = try GainFit.fit(Replay.run(Traces.standard, settings: cameraOnly), truthDepthMM: 50)
        var settings = cameraOnly
        settings.gain = fitted.gain
        let cameraOnlyNearer = try #require(
            try Replay.run(Traces.nearer, settings: settings).compared(with: Truth(depthMM: 50)).depthLocked)
        #expect(cameraOnlyNearer.bias > 15, "\(cameraOnlyNearer)")

        let lidarNearer = try #require(try Replay.run(Traces.nearer).compared(with: Truth(depthMM: 50)).depthLocked)
        #expect(abs(lidarNearer.bias) <= 1 && lidarNearer.medianAbsoluteError <= 1, "\(lidarNearer)")
    }

    /// Scoring the recording a gain came from would only grade the fit, so it is refused.
    @Test func theRecordingAGainCameFromIsNeverScoredWithIt() throws {
        let fitted = try GainFit.fit(Replay.run(Traces.standard), truthDepthMM: 50)
        let again = try Replay.run(Traces.standard, settings: .init(gain: fitted.gain))
        #expect(throws: ReplayFailure.scoredOnCalibrationTrace) { try again.compared(with: Truth(depthMM: 50)) }
        // The very same gain typed in by hand carries no origin, so nothing can be checked.
        let typed = try Replay.run(Traces.standard, settings: .init(gain: Gain(value: fitted.gain.value)))
        #expect(throws: Never.self) { try typed.compared(with: Truth(depthMM: 50)) }
    }

    /// Only locked pushes may set a gain; a recording with none has nothing to fit.
    @Test func aRecordingWithoutLockedPushesFitsNothing() throws {
        let still = try RecordedTrace(header: Traces.header,
                                      frames: Rig().frames(following: SyntheticSession.samples([.pause(3)], noiseMM: 0)))
        #expect(throws: ReplayFailure.nothingToFit) { try GainFit.fit(Replay.run(still), truthDepthMM: 50) }
    }

    /// The gain multiplies every height before the analyzer, so every depth grows by it.
    @Test func theGainScalesEveryDepth() throws {
        let plain = try Replay.run(Traces.standard)
        let scaled = try Replay.run(Traces.standard, settings: .init(gain: Gain(value: 1.1)))
        #expect(plain.strokes.count == scaled.strokes.count)
        for (before, after) in zip(plain.strokes, scaled.strokes) {
            #expect(abs(after.depthMM / before.depthMM - 1.1) < 0.01)
        }
    }
}
