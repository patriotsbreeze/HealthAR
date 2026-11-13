import Foundation
import PlumbContracts
import Testing
@testable import PlumbReplay

/// The numbers a replay is summed up and scored with, on results made by hand.
@Suite struct ReportTests {
    private let fingerprint = TraceFingerprint(of: Data("a recording".utf8))

    /// Four pushes: two locked, one estimating, then one after a pause with no interval.
    private var result: ReplayResult {
        let rows: [(t: Double, depth: Double, interval: Double?, lock: LockState)] = [
            (1.0, 48, nil, .locked), (1.5, 52, 0.5, .locked), (2.1, 60, 0.6, .estimating), (6.0, 40, nil, .locked),
        ]
        let strokes = rows.enumerated().map { index, row in
            StrokeRow(compression: Compression(index: index + 1, tTop: row.t - 0.2, tBottom: row.t, depthMM: row.depth,
                                               intervalS: row.interval, lock: row.lock),
                      reportedAt: row.t + 0.1 * Double(index + 1))
        }
        return ReplayResult(traceFingerprint: fingerprint, method: .alongRay, range: .measured,
                            gain: .unit, frameCount: 600, sampleCount: 590, placementCount: 0, span: 0...10,
                            strokes: strokes, lockedSeconds: 7.5, rangeMedianM: 0.92)
    }

    @Test func theSummaryIsMediansAndShares() throws {
        let summary = result.summary
        #expect(summary.count == 4 && summary.lockedCount == 3)
        // Median of 0.5 and 0.6 seconds is 0.55, which is 109.1 a minute.
        #expect(abs(try #require(summary.ratePerMin) - 60 / 0.55) < 1e-9)
        #expect(summary.depthMedianMM == 50)
        // Quartiles of 40, 48, 52, 60 by interpolation: 46 and 54.
        #expect(summary.depthSpreadMM == 8)
        #expect(summary.lockedShare == 0.75)
        #expect(abs(try #require(summary.delayMedianS) - 0.25) < 1e-9)
        #expect(abs(try #require(summary.delayLongestS) - 0.4) < 1e-9)
        #expect(summary.rangeMedianM == 0.92)
    }

    @Test func anEmptyReplaySumsToNothing() {
        let empty = ReplayResult(traceFingerprint: fingerprint, method: .alongRay, range: .measured,
                                 gain: .unit, frameCount: 0, sampleCount: 0, placementCount: 0, span: nil,
                                 strokes: [], lockedSeconds: 0, rangeMedianM: nil)
        let summary = empty.summary
        #expect(summary.count == 0 && summary.ratePerMin == nil && summary.depthMedianMM == nil)
        #expect(summary.lockedShare == nil && summary.delayMedianS == nil)
    }

    @Test func errorsAreMeasuredMinusTruth() throws {
        let stats = try #require(ErrorStats(errors: [-2, 1, 3, 4]))
        #expect(stats.n == 4)
        #expect(stats.medianAbsoluteError == 2.5)
        #expect(stats.bias == 1.5)
        #expect(stats.lowest == -2 && stats.highest == 4)
        #expect(ErrorStats(errors: []) == nil)
    }

    @Test func depthIsScoredOnLockedPushesAndOnAllRateOnEveryInterval() throws {
        let report = try result.compared(with: Truth(depthMM: 50, ratePerMin: 100))
        let locked = try #require(report.depthLocked)
        #expect(locked.n == 3 && locked.bias == (-2 + 2 - 10) / 3.0)
        #expect(try #require(report.depthAll).n == 4)
        let rate = try #require(report.rate)
        #expect(rate.n == 2)
        #expect(abs(rate.highest - 20) < 1e-9 && abs(rate.lowest - 0) < 1e-9)
        #expect(try result.compared(with: Truth(ratePerMin: 100)).depthAll == nil)
    }

    @Test func theTextListsThePushesAndTheScore() throws {
        var report = ReplayReport(traceName: "rig.jsonl", header: Traces.header, runs: [result],
                                  truth: Truth(depthMM: 50, ratePerMin: 100))
        report.scores = [try result.compared(with: report.truth)]
        let text = report.text
        #expect(text.contains("Trace     rig.jsonl  (\(fingerprint.value))"))
        #expect(text.contains("Note      Rig: flat plate, 50 mm travel"))
        #expect(text.contains("Heights   along the line of sight, LiDAR range"))
        let lines = text.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
        #expect(lines.contains(["#", "bottom", "s", "depth", "mm", "interval", "s", "trust", "delay", "s"]))
        #expect(lines.contains(["2", "1.500", "52.0", "0.500", "locked", "0.200"]))
        #expect(lines.contains(["3", "2.100", "60.0", "0.600", "estimating", "0.300"]))
        #expect(lines.contains(["4", "6.000", "40.0", "-", "locked", "0.400"]))
        #expect(text.contains("Against the truth: 50.0 mm a push, 100 a minute"))
        #expect(text.contains("depth, locked mm  3"))
        #expect(!text.contains("This recording set the gain"))
    }

    @Test func aFittedGainIsPrintedInsteadOfAScore() throws {
        let fitted = try GainFit.fit(result, truthDepthMM: 50)
        let report = ReplayReport(traceName: "rig.jsonl", header: Traces.header, runs: [result],
                                  truth: Truth(depthMM: 50), fitted: fitted)
        #expect(report.text.contains("Gain 1.042, fitted to 50.0 mm from 3 locked pushes with median 48.0 mm."))
        #expect(report.text.contains("Score a different recording with --gain 1.042."))
        #expect(!report.text.contains("Against the truth"))
    }

    @Test func aGainFittedBesideTheYardstickSaysWhichRunItIsFor() throws {
        var assumed = result
        assumed.range = .assumed(metres: 1)
        let report = ReplayReport(traceName: "rig.jsonl", header: Traces.header, runs: [result, assumed],
                                  truth: Truth(depthMM: 50), fitted: try GainFit.fit(assumed, truthDepthMM: 50))
        #expect(report.text.contains("Gain 1.042 for the assumed 1.00 m run, fitted to 50.0 mm"))
        #expect(report.text.contains("Score a different recording with --no-range --gain 1.042."))
    }

    /// The hint repeats whatever made the fitted run differ from the default one.
    @Test func theGainHintRepeatsTheRunsMethodAndRange() {
        var run = result
        #expect(ReplayReport.sameRunFlags(run) == "")
        run.method = .imagePlane
        #expect(ReplayReport.sameRunFlags(run) == "--method imagePlane ")
        run.range = .assumed(metres: 0.7)
        #expect(ReplayReport.sameRunFlags(run) == "--no-range --assume-range-m 0.7 ")
    }

    @Test func twoRunsStandSideBySideWithoutTheirPushes() {
        var assumed = result
        assumed.range = .assumed(metres: 1)
        assumed.method = .imagePlane
        let text = ReplayReport(traceName: "rig.jsonl", header: Traces.header, runs: [result, assumed]).text
        #expect(text.contains("LiDAR range  assumed 1.00 m"))
        #expect(text.contains("Heights   picture slide, no LiDAR, hands assumed 1.00 m away"))
        #expect(!text.contains("bottom s"))
    }

    @Test func theCSVHasOneLinePerPush() {
        let lines = ReplayReport(traceName: "rig.jsonl", header: Traces.header, runs: [result]).csv
            .split(separator: "\n").map(String.init)
        #expect(lines.first == "run,index,bottom_s,depth_mm,interval_s,trust,reported_s")
        #expect(lines.count == 5)
        #expect(lines[1] == "measured,1,1.000,48.00,,locked,1.100")
        #expect(lines[3] == "measured,3,2.100,60.00,0.600,estimating,2.400")
    }

    @Test func anErrorAlwaysShowsItsSignAndNeverAMinusZero() {
        #expect(Figure.signed(1.24, 1) == "+1.2")
        #expect(Figure.signed(-0.04, 1) == "+0.0")
        #expect(Figure.signed(-0.06, 1) == "-0.1")
        #expect(Figure.signed(nil, 1) == "-")
    }

    @Test func aTableLinesUpItsColumns() {
        var table = TextTable(["", "a", "words", "bbb"], wordColumns: [2])
        table.add(["first", "1", "on", "2"])
        table.add(["x", "100", "left", "-"])
        #expect(table.text == "         a  words  bbb\nfirst    1  on       2\nx      100  left     -")
    }
}
