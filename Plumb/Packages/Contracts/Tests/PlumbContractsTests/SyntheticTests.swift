import Foundation
import Testing
@testable import PlumbContracts

@Suite struct SyntheticTests {
    @Test func strokeIsTopAtStartAndBottomAtDownFraction() {
        #expect(SyntheticSession.strokeShape(phase: 0) == 0)
        #expect(abs(SyntheticSession.strokeShape(phase: SyntheticSession.downFraction) - 1) < 1e-9)
        #expect(SyntheticSession.strokeShape(phase: 0.9) == 0)
    }

    @Test func noiselessSamplesReachExactlyTheAskedDepth() {
        let segments = [SyntheticSegment(duration: 6, ratePerMin: 120, depthMM: 50)]
        let samples = SyntheticSession.samples(segments, sampleHz: 200, noiseMM: 0)
        let lowest = samples.map(\.heightMM).min() ?? 0
        #expect(abs(lowest + 50) < 0.1)
        #expect((samples.map(\.heightMM).max() ?? 1) == 0)
    }

    @Test func truthCountsOneBottomPerCycle() {
        let segments = [SyntheticSegment(duration: 6, ratePerMin: 120, depthMM: 50), .pause(3)]
        let truth = SyntheticSession.truth(segments)
        #expect(truth.bottoms.count == 12)
        #expect(truth.stillSpans == [6...9])
        #expect(abs(truth.bottoms[1].t - truth.bottoms[0].t - 0.5) < 1e-9)
    }

    @Test func sameSeedGivesSameSamples() {
        let a = SyntheticSession.samples(SyntheticSession.demo, seed: 7)
        let b = SyntheticSession.samples(SyntheticSession.demo, seed: 7)
        let c = SyntheticSession.samples(SyntheticSession.demo, seed: 8)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func logEntryRoundTripsThroughJSON() throws {
        let stroke = Compression(index: 3, tTop: 1.0, tBottom: 1.2, depthMM: 52, intervalS: 0.55, lock: .locked)
        let entry = LogEntry(id: 9, t: 1.2, source: .measured, body: .compression(stroke))
        let data = try JSONEncoder().encode(entry)
        #expect(try JSONDecoder().decode(LogEntry.self, from: data) == entry)
    }
}
