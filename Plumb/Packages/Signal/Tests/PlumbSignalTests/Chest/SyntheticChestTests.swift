import Foundation
import PlumbContracts
import Testing
@testable import PlumbSignal

@Suite struct SyntheticChestTests {
    @Test func theSameSeedGivesTheSameSamplesAndAnotherSeedDoesNot() {
        let first = SyntheticChest.samples(SyntheticChest.demo, seed: 31)
        #expect(first == SyntheticChest.samples(SyntheticChest.demo, seed: 31))
        #expect(first != SyntheticChest.samples(SyntheticChest.demo, seed: 32))
    }

    @Test func samplesAreEvenlySpacedAndCarryTheirQuality() throws {
        let samples = SyntheticChest.samples(SyntheticChest.demo, sampleHz: 30, quality: 0.7, startT: 5)
        #expect(samples.count == 45 * 30)
        #expect(samples.first?.t == 5)
        for (earlier, later) in zip(samples, samples.dropFirst()) {
            #expect(abs(later.t - earlier.t - 1.0 / 30) < 1e-9)
        }
        #expect(samples.allSatisfy { $0.quality == 0.7 })
    }

    @Test func theDemoMovesFifteenTimesAMinuteFourMillimetresEitherWayThenHoldsStill() throws {
        let samples = SyntheticChest.samples(SyntheticChest.demo, noiseMM: 0)
        let moving = samples.filter { $0.t < 20 }.map(\.heightMM)
        #expect(abs(try #require(moving.max()) - 4) < 0.01)
        #expect(abs(try #require(moving.min()) + 4) < 0.01)
        // Five whole rises and falls: back to the middle each four seconds.
        for second in [4.0, 8, 12, 16] {
            let sample = try #require(samples.first { abs($0.t - second) < 1e-9 })
            #expect(abs(sample.heightMM) < 1e-9)
        }
        #expect(samples.filter { $0.t >= 20 }.allSatisfy { abs($0.heightMM) < 1e-9 })
    }

    @Test func aStillStretchHoldsWhereTheMovementLeftOff() {
        // A quarter rise past the fifth: the chest is at its highest when it stops.
        let samples = SyntheticChest.samples([.moving(21), .still(5), .moving(2)], noiseMM: 0)
        #expect(samples.filter { $0.t >= 21 && $0.t < 26 }.allSatisfy { abs($0.heightMM - 4) < 1e-9 })
        // Moving again carries on from that height without a jump.
        let resumed = samples.first { $0.t >= 26 }
        #expect(resumed.map { abs($0.heightMM - 4) < 1e-9 } == true)
    }

    @Test func driftAndNoiseAreAddedOnTop() throws {
        let drifting = SyntheticChest.samples([.still(60)], noiseMM: 0, driftMMPerMin: 6)
        let last = try #require(drifting.last)
        let expected: Double = 6 * last.t / 60
        #expect(abs(last.heightMM - expected) < 1e-9)
        let noisy = SyntheticChest.samples([.still(60)], noiseMM: 0.8, seed: 33).map(\.heightMM)
        let mean = noisy.reduce(0, +) / Double(noisy.count)
        let spread = sqrt(noisy.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(noisy.count))
        #expect(abs(mean) < 0.05)
        #expect(abs(spread - 0.8) < 0.05)
    }
}
