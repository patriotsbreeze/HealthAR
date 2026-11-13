import Foundation
import PlumbContracts
import Testing
@testable import PlumbSignal

@Suite struct TimingTests {
    @Test(arguments: Sampling.allCases, Pace.grid)
    func everyCompressionIsReportedWithinAQuarterSecond(sampling: Sampling, pace: Pace) throws {
        let truth = SyntheticSession.truth(steady(rate: pace.rate, depth: pace.depth))
        let run = play(sampling.samples(pace, seed: 2))
        var slowest = 0.0
        for report in run.reported {
            guard case .compression(let stroke) = report.event else { continue }
            let bottom = try #require(nearest(truth.bottoms, to: stroke.tBottom))
            slowest = max(slowest, report.at - bottom.t)
            #expect(report.at >= stroke.tBottom)
        }
        #expect(slowest <= 0.25, "slowest report came \(slowest) s after the deepest point")
    }

    @Test func atSixtyHertzReportsUsuallyComeWellInsideTheAim() throws {
        var delays: [Double] = []
        for pace in Pace.grid {
            let truth = SyntheticSession.truth(steady(rate: pace.rate, depth: pace.depth))
            let run = play(Sampling.sixtyHz.samples(pace))
            for report in run.reported {
                guard case .compression(let stroke) = report.event else { continue }
                delays.append(report.at - (try #require(nearest(truth.bottoms, to: stroke.tBottom))).t)
            }
        }
        #expect(median(delays) < 0.1)
        #expect((delays.max() ?? 1) < 0.2)
    }

    @Test func slowShallowAndFastDeepStrokesAreBothFound() throws {
        for pace in [Pace(rate: 80, depth: 20), Pace(rate: 140, depth: 70), Pace(rate: 60, depth: 40)] {
            let truth = SyntheticSession.truth(steady(rate: pace.rate, depth: pace.depth))
            let run = play(Sampling.sixtyHz.samples(pace))
            #expect(abs(run.compressions.count - truth.bottoms.count) <= 1, "\(pace.testDescription)")
            #expect(abs(median(run.compressions.map(\.depthMM)) - pace.depth) <= 3, "\(pace.testDescription)")
            #expect(abs(try #require(run.analyzer.metrics.ratePerMin) - pace.rate) <= 2, "\(pace.testDescription)")
        }
    }

    @Test func tinyMovementsBelowTheShallowestCountedDepthAreNotCompressions() {
        let run = play(Sampling.sixtyHz.samples(Pace(rate: 110, depth: 8), noiseMM: 1))
        #expect(run.compressions.isEmpty)
    }

    @Test func theShallowestCountedDepthFollowsTheTargets() {
        let samples = Sampling.sixtyHz.samples(Pace(rate: 110, depth: 22), noiseMM: 1)
        let adult = play(samples)
        #expect(adult.compressions.count >= 35)

        // With a target of 100 mm, 0.3 of it is 30 mm, so 22 mm strokes no longer count.
        let deepTargets = Targets(depthMinMM: 100, depthMaxMM: 120)
        let strict = play(samples, into: CompressionAnalyzer(targets: deepTargets))
        #expect(strict.compressions.isEmpty)
    }

    @Test func configurationChangesBehaviour() {
        let samples = SyntheticSession.samples(PauseTests.stopAndGo, noiseMM: 2, seed: 3)
        var patient = CompressionAnalyzer.Config()
        patient.pauseAfterS = 8
        #expect(play(samples, into: CompressionAnalyzer(config: patient)).pauseStarts.isEmpty)

        var hasty = CompressionAnalyzer.Config()
        hasty.pauseAfterS = 1
        let run = play(samples, into: CompressionAnalyzer(config: hasty))
        #expect(run.pauseStarts.count == 2, "the stop in the middle and the stop at the end")
    }
}
