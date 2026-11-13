import Foundation
import Testing
import PlumbContracts
@testable import PlumbGeometry

@Suite struct ShiftEstimatorTests {
    static let rows = 96
    static let columns = 32
    static let pitchPx = 3.3

    /// A patch showing a smooth random pattern whose content sits `rowsUp` rows higher in the
    /// world than in the unshifted patch with the same seed.
    private func textured(seed: UInt64, rowsUp: Double = 0, gain: Double = 1, lift: Double = 0) -> LumaPatch {
        let texture = Texture(seed: seed, cell: 4, x: 0...Double(Self.columns), y: -40...Double(Self.rows + 40))
        var pixels: [UInt8] = []
        for row in 0..<Self.rows {
            for column in 0..<Self.columns {
                // Rows count downward, so content that moved up now shows what was further down.
                let shade = texture.value(Double(column), Double(row) + rowsUp)
                let level = (40 + 180 * shade) * gain + lift
                pixels.append(UInt8(min(max(level.rounded(), 0), 255)))
            }
        }
        return LumaPatch(width: Self.columns, height: Self.rows, pitchPx: Self.pitchPx, pixels: pixels)
    }

    /// Runs one patch through the estimator; the macro `#require` cannot wrap a mutating call itself.
    private func match(_ estimator: inout ShiftEstimator, _ patch: LumaPatch) throws -> (upPx: Double, correlation: Double) {
        let found = estimator.estimate(patch)
        return try #require(found)
    }

    @Test func theFirstPatchBecomesTheKeyFrame() throws {
        var estimator = ShiftEstimator()
        let first = try match(&estimator, textured(seed: 1, rowsUp: 7))
        #expect(first.upPx == 0)
        #expect(first.correlation == 1)

        let same = try match(&estimator, textured(seed: 1, rowsUp: 7))
        #expect(abs(same.upPx) < 0.05)
        #expect(same.correlation > 0.999)
    }

    @Test func itRecoversWholeAndHalfRowShifts() throws {
        var estimator = ShiftEstimator()
        _ = estimator.estimate(textured(seed: 2))
        for halfRows in -40...40 {
            let rowsUp = Double(halfRows) / 2
            let found = try match(&estimator, textured(seed: 2, rowsUp: rowsUp))
            #expect(abs(found.upPx / Self.pitchPx - rowsUp) < 0.15, "asked for \(rowsUp) rows")
            #expect(found.correlation > 0.9, "asked for \(rowsUp) rows")
        }
    }

    @Test func positiveMeansTheContentMovedUpInTheWorld() throws {
        // Row 0 is the highest row. Put one bright bar low in the key frame, then higher.
        func bar(atRow barRow: Int) -> LumaPatch {
            let pixels = (0..<(Self.rows * Self.columns)).map { index -> UInt8 in
                abs(index / Self.columns - barRow) < 4 ? 220 : 40
            }
            return LumaPatch(width: Self.columns, height: Self.rows, pitchPx: Self.pitchPx, pixels: pixels)
        }
        var estimator = ShiftEstimator()
        _ = estimator.estimate(bar(atRow: 50))
        let raised = try match(&estimator, bar(atRow: 40))
        #expect(abs(raised.upPx - 10 * Self.pitchPx) < 0.5)
        let lowered = try match(&estimator, bar(atRow: 58))
        #expect(abs(lowered.upPx + 8 * Self.pitchPx) < 0.5)
    }

    @Test func itReportsLowCorrelationOnUnrelatedContent() throws {
        // The best of 77 slides over a picture that has nothing to do with the key frame. Chance
        // alone lifts a few of these past the 0.5 at which the height estimator takes a new key
        // frame, so the claim is about how often, not never.
        var scores: [Double] = []
        for seed in UInt64(1)...200 {
            var estimator = ShiftEstimator()
            _ = estimator.estimate(textured(seed: seed))
            scores.append(try match(&estimator, textured(seed: seed + 5000)).correlation)
        }
        scores.sort()
        #expect(scores[scores.count / 2] < 0.4, "median \(scores[scores.count / 2])")
        let pastTheFloor = scores.filter { $0 >= 0.5 }.count
        #expect(pastTheFloor <= scores.count / 20, "\(pastTheFloor) of \(scores.count) scored 0.5 or more")
        #expect((scores.last ?? 1) < 0.7)
    }

    @Test func aSingleWholeRowProfileCannotTellUnrelatedContentApart() throws {
        // Why the default cuts the patch into strips: with one profile of whole-row means, most
        // unrelated pictures find some slide that scores past the floor.
        var pastTheFloor = 0
        for seed in UInt64(1)...100 {
            var estimator = ShiftEstimator(config: .init(bands: 1))
            _ = estimator.estimate(textured(seed: seed))
            if try match(&estimator, textured(seed: seed + 5000)).correlation >= 0.5 { pastTheFloor += 1 }
        }
        #expect(pastTheFloor > 50)
    }

    @Test func brightnessAndContrastChangesDoNotMoveTheAnswer() throws {
        var estimator = ShiftEstimator()
        _ = estimator.estimate(textured(seed: 4))
        let dimmer = try match(&estimator, textured(seed: 4, rowsUp: -6.5, gain: 0.6, lift: 25))
        #expect(abs(dimmer.upPx / Self.pitchPx + 6.5) < 0.15)
        #expect(dimmer.correlation > 0.9)
    }

    @Test func rekeyStartsAgainFromTheNextPatch() throws {
        var estimator = ShiftEstimator()
        _ = estimator.estimate(textured(seed: 5))
        estimator.rekey()
        let fresh = try match(&estimator, textured(seed: 5, rowsUp: 9))
        #expect(fresh.upPx == 0)
        #expect(fresh.correlation == 1)
        let after = try match(&estimator, textured(seed: 5, rowsUp: 12))
        #expect(abs(after.upPx / Self.pitchPx - 3) < 0.15)
    }

    @Test func aFlatPatchMatchesNothing() throws {
        let flat = LumaPatch(width: Self.columns, height: Self.rows, pitchPx: Self.pitchPx,
                             pixels: [UInt8](repeating: 128, count: Self.rows * Self.columns))
        var estimator = ShiftEstimator()
        _ = estimator.estimate(textured(seed: 6))
        #expect(try match(&estimator, flat).correlation == 0)

        var flatKey = ShiftEstimator()
        _ = flatKey.estimate(flat)
        #expect(try match(&flatKey, flat).correlation == 0)
    }

    @Test func aMalformedPatchIsRefusedAndARespacedOneMatchesNothing() throws {
        var estimator = ShiftEstimator()
        _ = estimator.estimate(textured(seed: 7))
        let short = LumaPatch(width: Self.columns, height: Self.rows, pitchPx: Self.pitchPx, pixels: [1, 2, 3])
        #expect(estimator.estimate(short) == nil)

        var respaced = textured(seed: 7)
        respaced.pitchPx = 2.0
        let mismatched = try match(&estimator, respaced)
        #expect(mismatched.upPx == 0)
        #expect(mismatched.correlation == 0)

        // The key frame is untouched: the original grid still matches it.
        #expect(try match(&estimator, textured(seed: 7)).correlation > 0.999)
    }

    @Test func aSingleProfileOfWholeRowsAlsoRecoversShifts() throws {
        var estimator = ShiftEstimator(config: .init(templateFraction: 1, bands: 1))
        _ = estimator.estimate(textured(seed: 8))
        for rowsUp in [-20.0, -7.5, 0.5, 13, 20] {
            let found = try match(&estimator, textured(seed: 8, rowsUp: rowsUp))
            #expect(abs(found.upPx / Self.pitchPx - rowsUp) < 0.15)
        }
    }

    @Test func aPatchSurvivesJSON() throws {
        let original = textured(seed: 9)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(LumaPatch.self, from: data) == original)
    }
}
