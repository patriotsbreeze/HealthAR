import Foundation
import Testing
@testable import PlumbReplay

/// `plumb-replay` from end to end, on trace files written the way the phone writes them.
@Suite struct CommandTests {
    private func run(_ arguments: [String]) throws -> String {
        guard case .replay(let options) = try ReplayOptions.parse(arguments) else { return "" }
        return try ReplayCommand.run(options)
    }

    @Test func aTraceIsReplayedAndScored() throws {
        let folder = try TemporaryFolder()
        let path = try folder.write(Traces.standard, as: "a.jsonl")
        let text = try run([path, "--truth-depth-mm", "50", "--truth-rate", "110"])
        #expect(text.contains("Trace     a.jsonl"))
        #expect(text.contains("pushes counted"))
        #expect(text.contains("Against the truth: 50.0 mm a push, 110 a minute"))
        #expect(text.contains("depth, locked mm"))
    }

    @Test func theCSVIsWrittenWhereAskedWithALinePerPush() throws {
        let folder = try TemporaryFolder()
        let path = try folder.write(Traces.standard, as: "a.jsonl")
        let csv = folder.file("pushes.csv")
        _ = try run([path, "--csv", csv.path])
        let lines = try String(contentsOf: csv, encoding: .utf8).split(separator: "\n")
        let pushes = try Replay.run(Traces.standard).strokes.count
        #expect(lines.count == 1 + pushes)
        #expect(lines.dropFirst().allSatisfy { $0.hasPrefix("measured,") })
    }

    /// Fitting prints the gain and how to use it, and scores nothing.
    @Test func fittingAGainPrintsItAndScoresNothing() throws {
        let folder = try TemporaryFolder()
        let path = try folder.write(Traces.standard, as: "a.jsonl")
        let text = try run([path, "--fit-gain", "--truth-depth-mm", "50", "--truth-rate", "110"])
        #expect(text.contains("This recording set the gain, so it is not scored."))
        #expect(text.contains("--gain 1.0"))
        #expect(!text.contains("Against the truth"))
    }

    /// Calibrate on one recording, score another, in one go; the same recording twice is refused.
    @Test func aGainFromAnotherRecordingIsUsedAndTheSameRecordingIsRefused() throws {
        let folder = try TemporaryFolder()
        let calibration = try folder.write(Traces.standard, as: "a.jsonl")
        let scored = try folder.write(Traces.sameDistance, as: "b.jsonl")
        let text = try run([scored, "--gain-from", calibration, "--truth-depth-mm", "50"])
        #expect(text.contains("Against the truth: 50.0 mm a push"))
        #expect(text.contains(", gain 1.0"))

        // A copy under another name is still the same recording.
        let copy = folder.file("a-copy.jsonl")
        try FileManager.default.copyItem(atPath: calibration, toPath: copy.path)
        #expect(throws: ReplayFailure.scoredOnCalibrationTrace) {
            try run([copy.path, "--gain-from", calibration, "--truth-depth-mm", "50"])
        }
    }

    /// Without the range, the camera-only run stands next to the LiDAR run of the same frames.
    @Test func withoutTheRangeBothRunsArePrinted() throws {
        let folder = try TemporaryFolder()
        let path = try folder.write(Traces.standard, as: "a.jsonl")
        let csv = folder.file("both.csv")
        let text = try run([path, "--no-range", "--truth-depth-mm", "50", "--csv", csv.path])
        #expect(text.contains("LiDAR range  assumed 1.00 m"))
        // The yardstick is the app's own method, with no gain: the picture slide reads short even with LiDAR.
        #expect(text.contains("Heights   along the line of sight, LiDAR range"))
        #expect(text.contains("Heights   picture slide, no LiDAR, hands assumed 1.00 m away"))
        let runs = Set(try String(contentsOf: csv, encoding: .utf8).split(separator: "\n").dropFirst()
            .map { $0.split(separator: ",")[0] })
        #expect(runs == ["measured", "assumed"])
    }

    /// The yardstick gets no gain, even when the camera-only run is given one.
    @Test func withoutTheRangeTheGainIsTheCameraOnlyRunsAlone() throws {
        let folder = try TemporaryFolder()
        let path = try folder.write(Traces.standard, as: "a.jsonl")
        let text = try run([path, "--no-range", "--gain", "1.2"])
        #expect(text.contains("Heights   along the line of sight, LiDAR range\n"))
        #expect(text.contains("Heights   picture slide, no LiDAR, hands assumed 1.00 m away, gain 1.200"))
    }

    /// A typo that names a trace as the CSV is refused before anything is written, however the path is spelled.
    @Test func theCSVNeverWritesOverATrace() throws {
        let folder = try TemporaryFolder()
        let path = try folder.write(Traces.standard, as: "a.jsonl")
        let calibration = try folder.write(Traces.sameDistance, as: "b.jsonl")
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let roundabout = folder.url.appendingPathComponent("sub/../a.jsonl", isDirectory: false).path
        #expect(throws: ReplayOptions.Failure.overwrites(flag: "--csv", path: path)) {
            try run([path, "--csv", path])
        }
        #expect(throws: ReplayOptions.Failure.overwrites(flag: "--csv", path: path)) {
            try run([path, "--csv", roundabout])
        }
        #expect(throws: ReplayOptions.Failure.overwrites(flag: "--csv", path: calibration)) {
            try run([path, "--gain-from", calibration, "--truth-depth-mm", "50", "--csv", calibration])
        }
        let link = folder.file("link.jsonl")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: path)
        #expect(throws: ReplayOptions.Failure.overwrites(flag: "--csv", path: path)) {
            try run([path, "--csv", link.path])
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
    }

    @Test func aMissingTraceIsAnError() {
        #expect(throws: (any Error).self) { try run(["/nowhere/at/all.jsonl"]) }
    }
}
