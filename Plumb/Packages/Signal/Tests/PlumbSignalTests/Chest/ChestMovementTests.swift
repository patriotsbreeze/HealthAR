import Foundation
import PlumbContracts
import Testing
@testable import PlumbSignal

@Suite struct ChestMovementTests {
    /// The analyzer the app makes, told the noise floor the synthetic chest is drawn with.
    private func analyzer(noiseFloorMM: Double? = 0.8) -> ChestMovementAnalyzer {
        ChestMovementAnalyzer(noiseFloorMM: noiseFloorMM)
    }

    // MARK: Movement and its absence

    @Test(arguments: [30.0, 60.0])
    func movementIsSeenWithinAFewSeconds(sampleHz: Double) throws {
        let samples = SyntheticChest.samples(SyntheticChest.demo, sampleHz: sampleHz, seed: 2)
        let run = watch(samples, into: analyzer())
        let seenAt = try #require(run.firstTime { $0.state.isMovementSeen })
        #expect(seenAt <= 10, "movement first seen at \(seenAt) s")
        // Never before the check has settled.
        #expect(seenAt >= ChestMovementAnalyzer.Config().settleS - 0.1)
        // And it stays seen for as long as the chest keeps moving.
        let moving = run.readings(from: seenAt, to: 20)
        #expect(moving.allSatisfy { $0.state.isMovementSeen })
        #expect(!moving.contains { $0.startPushing })
    }

    @Test(arguments: [30.0, 60.0])
    func stillAfterMovementIsNoMovementAfterAboutTenSeconds(sampleHz: Double) throws {
        let samples = SyntheticChest.samples(SyntheticChest.demo, sampleHz: sampleHz, seed: 3)
        let run = watch(samples, into: analyzer())
        let quietAt = try #require(run.firstTime { $0.state.isNoMovementSeen })
        #expect(quietAt >= 29 && quietAt <= 31, "no movement reported at \(quietAt) s, still from 20 s")
        let promptedAt = try #require(run.last?.promptedAt)
        #expect(promptedAt >= 29 && promptedAt <= quietAt)

        // The count keeps going up while the chest stays still.
        let end = try #require(run.last)
        let quiet = try #require(end.state.quietSeconds)
        #expect(abs(quiet - (end.t - 20)) < 1, "\(quiet) s quiet at \(end.t) s")
        #expect(end.startPushing)
    }

    @Test func aChestHeldAtTheTopOfItsRiseIsStillQuiet() throws {
        // Five and a quarter rises end at the highest point, so the chest is held 4 mm above its middle.
        let segments: [SyntheticChest.Segment] = [.moving(21), .still(20)]
        let run = watch(SyntheticChest.samples(segments, seed: 4), into: analyzer())
        let quietAt = try #require(run.firstTime { $0.state.isNoMovementSeen })
        #expect(quietAt >= 30 && quietAt <= 32, "no movement reported at \(quietAt) s, still from 21 s")
        // Holding still is never mistaken for movement once the last rise has left the window.
        let held = run.readings(from: 21 + ChestMovementAnalyzer.Config().windowS, to: 41)
        #expect(!held.isEmpty && !held.contains { $0.state.isMovementSeen })
    }

    @Test func aChestStillFromTheStartReachesNoMovementAfterTenSeconds() throws {
        let run = watch(SyntheticChest.samples([.still(15)], seed: 5), into: analyzer())
        #expect(!run.readings.contains { $0.state.isMovementSeen })
        let quietAt = try #require(run.firstTime { $0.state.isNoMovementSeen })
        #expect(quietAt >= 9.9 && quietAt <= 10.3)
        #expect(run.readings(from: 0, to: 9.8).allSatisfy { $0.state == .settling })
    }

    // MARK: The threshold

    @Test func theThresholdIsTwoMillimetresOrThreeTimesTheNoiseFloor() {
        #expect(ChestMovementAnalyzer().thresholdMM == 2)
        #expect(ChestMovementAnalyzer(noiseFloorMM: 0.5).thresholdMM == 2)
        #expect(ChestMovementAnalyzer(noiseFloorMM: 1).thresholdMM == 3)
        #expect(ChestMovementAnalyzer(noiseFloorMM: 2.5).thresholdMM == 7.5)
        #expect(ChestMovementAnalyzer(noiseFloorMM: .nan).thresholdMM == 2)
        #expect(ChestMovementAnalyzer(noiseFloorMM: -1).thresholdMM == 2)
        var analyzer = ChestMovementAnalyzer()
        analyzer.noiseFloorMM = 1.2
        #expect(abs(analyzer.tick(now: 1).thresholdMM - 3.6) < 1e-12)
    }

    @Test(arguments: [(30.0, UInt64(1)), (30, 2), (30, 3), (60, 4), (60, 5), (60, 6)])
    func noiseAtTheReportedFloorIsNeverMovement(sampleHz: Double, seed: UInt64) throws {
        for floor in [0.5, 0.8, 1.5] {
            let samples = SyntheticChest.samples([.still(40)], sampleHz: sampleHz, noiseMM: floor, seed: seed)
            let run = watch(samples, into: analyzer(noiseFloorMM: floor))
            #expect(!run.readings.contains { $0.state.isMovementSeen }, "noise \(floor) mm, seed \(seed)")
            let end = try #require(run.last)
            let quiet = try #require(end.state.quietSeconds)
            #expect(quiet > 38, "noise \(floor) mm, seed \(seed): quiet for only \(quiet) s")
        }
    }

    @Test(arguments: [UInt64(7), 8, 9])
    func aSwingJustUnderTheThresholdIsNotMovementAndJustOverIs(seed: UInt64) throws {
        let floor = 1.0
        let threshold = analyzer(noiseFloorMM: floor).thresholdMM
        func run(swingShare: Double) -> ChestWatch {
            let amplitude = swingShare * threshold / 2
            let samples = SyntheticChest.samples([.moving(30, amplitudeMM: amplitude)], noiseMM: 0.3, seed: seed)
            return watch(samples, into: analyzer(noiseFloorMM: floor))
        }

        let under = run(swingShare: 0.8)
        #expect(!under.readings.contains { $0.state.isMovementSeen })
        #expect(under.last?.state.isNoMovementSeen == true)
        #expect(try #require(under.last?.swingMM) < threshold)

        let over = run(swingShare: 1.25)
        #expect(over.readings(from: 4, to: 30).allSatisfy { $0.state.isMovementSeen })
        #expect(!over.readings.contains { $0.startPushing })
        #expect(try #require(over.last?.swingMM) >= threshold)
    }

    @Test func aSlowDriftIsNotMovement() throws {
        let samples = SyntheticChest.samples([.still(40)], driftMMPerMin: 6, seed: 10)
        let run = watch(samples, into: analyzer())
        #expect(!run.readings.contains { $0.state.isMovementSeen })
        #expect(try #require(run.last?.state.quietSeconds) > 38)
    }

    @Test(arguments: [30.0, 60.0])
    func aLoneSpikeIsNotMovement(sampleHz: Double) throws {
        var samples = SyntheticChest.samples([.still(20)], sampleHz: sampleHz, seed: 11)
        let index = try #require(samples.firstIndex { $0.t >= 12 })
        samples[index].heightMM += 40
        let run = watch(samples, into: analyzer())
        #expect(!run.readings.contains { $0.state.isMovementSeen })
        #expect(try #require(run.last?.state.quietSeconds) > 19)
    }

    // MARK: Unmeasured

    @Test func lowQualityIsUnmeasured() {
        let samples = SyntheticChest.samples(SyntheticChest.demo, quality: 0.1, seed: 12)
        let run = watch(samples, into: analyzer())
        #expect(!run.readings.isEmpty)
        for reading in run.readings {
            #expect(reading.state == .unmeasured)
            #expect(!reading.startPushing)
            #expect(reading.swingMM == nil)
            #expect(reading.trace.valuesMM.allSatisfy { $0 == nil })
            #expect(reading.trace.bandMM == nil)
        }
    }

    @Test func qualityFallingAwayIsUnmeasuredWithinASecond() throws {
        let samples = SyntheticChest.samples(SyntheticChest.demo, seed: 13).map {
            HeightSample(t: $0.t, heightMM: $0.heightMM, quality: $0.t < 15 ? 0.9 : 0.1)
        }
        let run = watch(samples, into: analyzer())
        let lostAt = try #require(run.readings.first { $0.t > 10 && $0.state == .unmeasured }?.t)
        #expect(lostAt > 15 && lostAt <= 16.1)
        #expect(run.readings(from: lostAt, to: 45).allSatisfy { $0.state == .unmeasured })
        #expect(run.last?.startPushing == false, "a chest that cannot be seen is never reported still")
    }

    @Test func timeNotSeenIsNotCountedAsQuiet() throws {
        // Moving, then eight seconds with no samples at all, then six seconds of a still chest.
        let all = SyntheticChest.samples([.moving(20), .still(14)], seed: 14)
        let samples = all.filter { $0.t < 20 || $0.t >= 28 }
        let run = watch(samples, into: analyzer())
        #expect(run.readings(from: 21.2, to: 27.9).allSatisfy { $0.state == .unmeasured })
        // Back from the gap the check settles again, and six seconds of stillness is not ten.
        let back = run.readings(from: 28.1, to: 34)
        #expect(!back.isEmpty)
        #expect(back.allSatisfy { $0.state == .settling })
        #expect(run.last?.startPushing == false)
    }

    @Test func nothingIsKnownBeforeTheFirstSample() {
        var analyzer = ChestMovementAnalyzer()
        let reading = analyzer.tick(now: 5)
        #expect(reading.t == 5)
        #expect(reading.state == .unmeasured)
        #expect(!reading.startPushing)
        #expect(reading.promptedAt == nil)
        #expect(reading.trace.valuesMM.count == 300)
        #expect(reading.trace.valuesMM.allSatisfy { $0 == nil })
    }

    @Test func samplesOutOfOrderOrNotNumbersAreIgnoredAndTimeNeverRunsBackwards() {
        var analyzer = ChestMovementAnalyzer()
        analyzer.ingest(HeightSample(t: 1, heightMM: 0))
        analyzer.ingest(HeightSample(t: 0.5, heightMM: 50))
        analyzer.ingest(HeightSample(t: .nan, heightMM: 50))
        analyzer.ingest(HeightSample(t: 1.1, heightMM: .infinity))
        #expect(analyzer.tick(now: 1.2).state == .settling)
        #expect(analyzer.tick(now: 0.2).t == 1.2)
        #expect(analyzer.tick(now: .nan).t == 1.2)
    }

    // MARK: The trace

    @Test func theTraceShowsTheLastThirtySecondsNewestLast() throws {
        let samples = SyntheticChest.samples([.moving(20)], seed: 15)
        let reading = try #require(watch(samples, into: analyzer()).last)
        let trace = reading.trace
        #expect(trace.stepS == 0.1)
        #expect(trace.valuesMM.count == 300)
        #expect(abs(trace.bandShare - 8.0 / 30) < 1e-12)
        // Twenty seconds measured, less the smoothing's first moments: the oldest third of the trace is empty.
        let measured = trace.valuesMM.compactMap { $0 }
        #expect(measured.count >= 190 && measured.count <= 195)
        #expect(trace.valuesMM.prefix(100).allSatisfy { $0 == nil })
        #expect(trace.valuesMM.suffix(190).allSatisfy { $0 != nil })
        // The rise and fall is 8 mm; smoothing takes a little off it, and the line is drawn about its middle.
        let swing = try #require(measured.max()) - (try #require(measured.min()))
        #expect(swing > 7 && swing < 8.5, "drawn swing \(swing) mm")
        #expect(abs(try #require(RobustStats.median(measured))) < 0.01)
        let band = try #require(trace.bandMM)
        #expect(abs(band.upperBound - band.lowerBound - reading.thresholdMM) < 1e-9)
        #expect(abs(try #require(reading.swingMM) - swing) < 1)
    }

    @Test func whenStillTheNewestPartOfTheLineSitsInsideTheBand() throws {
        let run = watch(SyntheticChest.samples([.moving(21), .still(25)], seed: 16), into: analyzer())
        let trace = try #require(run.last?.trace)
        let band = try #require(trace.bandMM)
        let judged = trace.valuesMM.suffix(Int(trace.bandShare * Double(trace.valuesMM.count))).compactMap { $0 }
        #expect(judged.count >= 75)
        #expect(judged.allSatisfy { band.contains($0) })
        // A full swing is wider than the band, so the moving part of the line runs outside it.
        let moving = trace.valuesMM.prefix(50).compactMap { $0 }
        #expect(moving.contains { !band.contains($0) })
    }

    @Test func theSameSamplesAlwaysGiveTheSameReadings() {
        let samples = SyntheticChest.samples([.moving(20), .still(15), .moving(10)], sampleHz: 30, seed: 17)
        let first = watch(samples, into: analyzer())
        let second = watch(samples, into: analyzer())
        #expect(first.readings == second.readings)
    }
}
