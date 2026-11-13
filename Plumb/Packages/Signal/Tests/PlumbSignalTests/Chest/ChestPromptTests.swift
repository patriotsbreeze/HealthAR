import Foundation
import PlumbContracts
import Testing
@testable import PlumbSignal

/// The safety rule: once "Start pushing" has been prompted, nothing the sensor sees takes it back.
/// Movement seen afterwards never means the person is all right. Only a person, through reset, clears it.
@Suite struct ChestPromptTests {
    /// Moving, still long enough to prompt, then moving again.
    private let story: [SyntheticChest.Segment] = [.moving(20), .still(15), .moving(15)]

    @Test func thePromptHoldsWhenMovementResumes() throws {
        let run = watch(SyntheticChest.samples(story, seed: 21), into: ChestMovementAnalyzer(noiseFloorMM: 0.8))
        let promptedAt = try #require(run.last?.promptedAt)
        #expect(promptedAt >= 29 && promptedAt <= 31)

        let after = run.readings.filter { $0.t >= promptedAt + 0.1 }
        #expect(after.count > 150)
        for reading in after {
            #expect(reading.startPushing, "prompt gone at \(reading.t) s")
            #expect(reading.promptedAt == promptedAt)
            #expect(reading.commandText == "Start pushing")
        }
        // The sensor does see the movement again, and says so, under the command that stays.
        let end = try #require(run.last)
        #expect(end.state == .movementSeen)
        #expect(end.contextText == "Chest movement seen")
        #expect(run.readings.filter { $0.t < promptedAt - 0.1 }.allSatisfy { !$0.startPushing })
    }

    @Test func thePromptHoldsWhenTheChestCannotBeSeen() throws {
        let segments: [SyntheticChest.Segment] = [.moving(20), .still(15)]
        let samples = SyntheticChest.samples(segments, seed: 22).map {
            HeightSample(t: $0.t, heightMM: $0.heightMM, quality: $0.t < 32 ? 1 : 0.05)
        }
        let run = watch(samples, into: ChestMovementAnalyzer(noiseFloorMM: 0.8), until: 40)
        let end = try #require(run.last)
        #expect(end.state == .unmeasured)
        #expect(end.startPushing)
        #expect(end.contextText == "Tap the chest on the picture")
    }

    @Test func thePromptHoldsWhenWatchingRestartsOrTheThresholdRises() throws {
        var analyzer = ChestMovementAnalyzer(noiseFloorMM: 0.8)
        let run = watch(SyntheticChest.samples([.moving(20), .still(12)], seed: 23), into: analyzer)
        analyzer = run.analyzer
        #expect(analyzer.tick(now: 32).startPushing)

        analyzer.restartWatching()
        analyzer.noiseFloorMM = 5
        let reading = analyzer.tick(now: 32.1)
        #expect(reading.state == .unmeasured)
        #expect(reading.startPushing)

        let more = watch(SyntheticChest.samples([.moving(10)], seed: 24, startT: 33), into: analyzer)
        #expect(more.readings.allSatisfy { $0.startPushing })
    }

    @Test func thePromptFiresWithoutAnyTicks() {
        var analyzer = ChestMovementAnalyzer(noiseFloorMM: 0.8)
        for sample in SyntheticChest.samples(SyntheticChest.demo, seed: 25) {
            analyzer.ingest(sample)
        }
        #expect(analyzer.tick(now: 45).startPushing)
    }

    @Test func onlyResetClearsThePrompt() throws {
        let samples = SyntheticChest.samples(story, seed: 26)
        let fresh = watch(samples, into: ChestMovementAnalyzer(noiseFloorMM: 0.8))
        var analyzer = fresh.analyzer
        #expect(analyzer.tick(now: 50).startPushing)

        analyzer.reset()
        let cleared = analyzer.tick(now: 50.1)
        #expect(!cleared.startPushing)
        #expect(cleared.promptedAt == nil)
        #expect(cleared.state == .unmeasured)
        #expect(cleared.trace.valuesMM.allSatisfy { $0 == nil })
        #expect(analyzer.noiseFloorMM == 0.8, "the noise floor describes the sensor, not the chest, so it is kept")

        // After a reset the check behaves exactly like a new one, reading for reading.
        let shifted = samples.map { HeightSample(t: $0.t + 60, heightMM: $0.heightMM, quality: $0.quality) }
        let again = watch(shifted, into: analyzer)
        let new = watch(shifted, into: ChestMovementAnalyzer(noiseFloorMM: 0.8))
        #expect(again.readings == new.readings)
    }

    @Test func resetKeepsTheConfiguration() {
        var config = ChestMovementAnalyzer.Config()
        config.noMovementAfterS = 6
        var analyzer = ChestMovementAnalyzer(config: config)
        analyzer.reset()
        #expect(analyzer.config.noMovementAfterS == 6)
    }

    @Test func thePromptIsLatchedTheFirstMomentItIsDue() {
        var latch = PromptLatch()
        #expect(!latch.isOn)
        latch.fire(at: 30)
        latch.fire(at: 42)
        #expect(latch.isOn)
        #expect(latch.firedAt == 30)
    }
}
