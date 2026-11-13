import Foundation
import Testing
import PlumbContracts
@testable import PlumbGeometry

@Suite struct NearestSurfaceTests {
    /// A 24x24 patch whose first `nearShare` of samples lie at `nearM` and the rest at `farM`.
    private func patch(nearM: Double, nearShare: Double, farM: Double, noiseM: Double = 0.003,
                       nearConfidence: UInt8 = 2, seed: UInt64 = 1) -> DepthPatch {
        var generator = SplitMix64(seed: seed)
        let side = 24
        let nearCount = Int((Double(side * side) * nearShare).rounded())
        var depths: [Float] = []
        var confidence: [UInt8] = []
        for index in 0..<(side * side) {
            let isNear = index < nearCount
            depths.append(Float((isNear ? nearM : farM) + noiseM * generator.nextGaussian()))
            confidence.append(isNear ? nearConfidence : 2)
        }
        return DepthPatch(width: side, height: side, depthsM: depths, confidence: confidence)
    }

    @Test func itReadsTheHandsAndNotTheBackground() throws {
        let reading = try #require(patch(nearM: 1.0, nearShare: 0.30, farM: 1.4).nearestSurface())
        #expect(abs(reading.depthM - 1.0) < 0.002)
        #expect(abs(reading.validFraction - 0.30) < 0.01)
    }

    @Test func itsMedianStaysWithinTwoMillimetresUnderThreeMillimetresOfNoise() throws {
        for seed in 1...50 {
            let truth = 0.6 + Double(seed) * 0.0137
            let reading = try #require(
                patch(nearM: truth, nearShare: 0.30, farM: truth + 0.4, seed: UInt64(seed)).nearestSurface())
            #expect(abs(reading.depthM - truth) < 0.002)
            // Normal noise of 3 mm has an interquartile range of about 4 mm.
            #expect(reading.spreadM > 0.002)
            #expect(reading.spreadM < 0.007)
        }
    }

    @Test func aPatchWithNothingValidReadsAsNil() {
        let junk: [Float] = [.nan, .infinity, -.infinity, 0, -1, 0.05, 9, 100]
        let depths = (0..<576).map { junk[$0 % junk.count] }
        let allJunk = DepthPatch(width: 24, height: 24, depthsM: depths, confidence: [UInt8](repeating: 2, count: 576))
        #expect(allJunk.nearestSurface() == nil)

        let allLow = DepthPatch(width: 24, height: 24, depthsM: [Float](repeating: 1, count: 576),
                                confidence: [UInt8](repeating: 0, count: 576))
        #expect(allLow.nearestSurface() == nil)
        #expect(allLow.nearestSurface(minConfidence: 0) != nil)

        #expect(DepthPatch(width: 0, height: 0, depthsM: [], confidence: []).nearestSurface() == nil)
    }

    @Test func lowConfidenceSamplesAreIgnored() throws {
        // A big, near, but untrusted blob in front of a trusted surface.
        let scene = patch(nearM: 0.5, nearShare: 0.30, farM: 1.0, nearConfidence: 0)
        let trusted = try #require(scene.nearestSurface())
        #expect(abs(trusted.depthM - 1.0) < 0.002)
        #expect(abs(trusted.validFraction - 0.70) < 0.01)

        let everything = try #require(scene.nearestSurface(minConfidence: 0))
        #expect(abs(everything.depthM - 0.5) < 0.002)

        // Medium confidence passes the default bar but not a bar of high.
        let medium = patch(nearM: 0.5, nearShare: 0.30, farM: 1.0, nearConfidence: 1)
        #expect(abs(try #require(medium.nearestSurface()).depthM - 0.5) < 0.002)
        #expect(abs(try #require(medium.nearestSurface(minConfidence: 2)).depthM - 1.0) < 0.002)
    }

    @Test func aPatchWithoutAConfidenceMapCountsAsTrusted() throws {
        var bare = patch(nearM: 1.0, nearShare: 0.5, farM: 1.4)
        bare.confidence = []
        #expect(abs(try #require(bare.nearestSurface(minConfidence: 2)).depthM - 1.0) < 0.002)
    }

    @Test func aSpeckleInFrontIsTooSmallToBeTheSurface() throws {
        let speckled = patch(nearM: 0.6, nearShare: 0.05, farM: 1.0)
        #expect(abs(try #require(speckled.nearestSurface()).depthM - 1.0) < 0.002)

        // Asked to accept small groups, the same speckle is the nearest surface.
        let lenient = DepthPatch.SurfaceConfig(minShare: 0.03)
        #expect(abs(try #require(speckled.nearestSurface(config: lenient)).depthM - 0.6) < 0.003)
    }

    @Test func smallGapsAreBridgedAndLargeOnesSplit() throws {
        // Two layers 3 cm apart read as one surface; 10 cm apart they are two.
        let close = try #require(patch(nearM: 1.00, nearShare: 0.5, farM: 1.03, noiseM: 0.001).nearestSurface())
        #expect(abs(close.validFraction - 1.0) < 0.01)
        #expect(close.spreadM > 0.02)

        let apart = try #require(patch(nearM: 1.00, nearShare: 0.5, farM: 1.10, noiseM: 0.001).nearestSurface())
        #expect(abs(apart.validFraction - 0.5) < 0.01)
        #expect(abs(apart.depthM - 1.0) < 0.001)
        #expect(apart.spreadM < 0.005)
    }

    @Test func depthsOutsideTheSaneRangeAreDropped() throws {
        let tooNear = patch(nearM: 0.10, nearShare: 0.4, farM: 2.0)
        #expect(abs(try #require(tooNear.nearestSurface()).depthM - 2.0) < 0.002)
        let tooFar = patch(nearM: 1.0, nearShare: 0.4, farM: 7.0)
        let reading = try #require(tooFar.nearestSurface())
        #expect(abs(reading.depthM - 1.0) < 0.002)
        #expect(abs(reading.validFraction - 0.4) < 0.01)
    }

    @Test func aPatchSurvivesJSONBitForBit() throws {
        var original = patch(nearM: 1.0, nearShare: 0.3, farM: 1.4)
        original.depthsM[0] = .nan
        original.depthsM[1] = .infinity
        let data = try JSONEncoder().encode(original)
        let copy = try JSONDecoder().decode(DepthPatch.self, from: data)
        #expect(copy.depthsM.map(\.bitPattern) == original.depthsM.map(\.bitPattern))
        #expect(copy.confidence == original.confidence)
        #expect(copy.width == 24)
        #expect(copy.height == 24)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DepthPatch.self, from: Data(#"{"width":1,"height":1,"depthsM":"AAA=","confidence":"Ag=="}"#.utf8))
        }
    }
}
