import Foundation
import PlumbGeometry

/// Everything `plumb-replay` does apart from printing, so all of it can be tested.
public enum ReplayCommand {
    /// Reads the trace, runs the replays the options ask for, writes the CSV when asked and returns
    /// the text to print. Throws when a file cannot be read or written, and `ReplayFailure` when a
    /// replay, a fit or a score is refused.
    public static func run(_ options: ReplayOptions) throws -> String {
        try refuseToOverwriteATrace(options)
        let trace = try RecordedTrace(contentsOf: URL(fileURLWithPath: options.tracePath))
        let range: RangeSource = options.withoutRange ? .assumed(metres: options.assumedRangeM) : .measured
        var settings = ReplaySettings(method: options.method, range: range)
        settings.gain = try gain(for: options, settings: settings)

        let main = try Replay.run(trace, settings: settings)
        // With the range taken away, the yardstick is the same frames as the app measures them: along the
        // line of sight with the LiDAR range, which needs no gain, so it gets none. The gain is fitted for
        // the camera-only run alone and soaks up both its guessed range and the picture slide's own error.
        let yardstick = options.withoutRange ? try Replay.run(trace, settings: .init(method: .alongRay)) : nil
        let runs = [yardstick, main].compactMap { $0 }

        var report = ReplayReport(traceName: URL(fileURLWithPath: options.tracePath).lastPathComponent,
                                  header: trace.header, runs: runs, truth: options.truth)
        if options.gain == .fit {
            guard let truthDepthMM = options.truth.depthMM else {
                throw ReplayOptions.Failure.needs("--fit-gain", "--truth-depth-mm")
            }
            report.fitted = try GainFit.fit(main, truthDepthMM: truthDepthMM)
        } else if !options.truth.isEmpty {
            report.scores = try runs.map { try $0.compared(with: options.truth) }
        }
        if let csvPath = options.csvPath {
            try Data(report.csv.utf8).write(to: URL(fileURLWithPath: csvPath))
        }
        return report.text
    }

    /// Throws when `--csv` names the trace or the calibration trace: writing the pushes there would
    /// replace a recording.
    private static func refuseToOverwriteATrace(_ options: ReplayOptions) throws {
        guard let csvPath = options.csvPath else { return }
        var traces = [options.tracePath]
        if case .fittedOn(let path) = options.gain { traces.append(path) }
        if let clash = traces.first(where: { sameFile(csvPath, $0) }) {
            throw ReplayOptions.Failure.overwrites(flag: "--csv", path: clash)
        }
    }

    /// True when two paths name one file: the same path once `.`, `..` and links are resolved, or, when
    /// both exist, the same file on disk, which also catches a hard link or a name differing only in case.
    static func sameFile(_ first: String, _ second: String) -> Bool {
        let one = URL(fileURLWithPath: first).standardizedFileURL.resolvingSymlinksInPath()
        let other = URL(fileURLWithPath: second).standardizedFileURL.resolvingSymlinksInPath()
        if one.path == other.path { return true }
        guard let oneID = try? one.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let otherID = try? other.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        else { return false }
        return oneID.isEqual(otherID)
    }

    /// The gain the main run uses. `--gain-from` replays the calibration trace with the same
    /// settings and fits there; the score later refuses if that trace is this one.
    private static func gain(for options: ReplayOptions, settings: ReplaySettings) throws -> Gain {
        switch options.gain {
        case .none, .fit:
            return .unit
        case .value(let value):
            return Gain(value: value)
        case .fittedOn(let path):
            guard let truthDepthMM = options.truth.depthMM else {
                throw ReplayOptions.Failure.needs("--gain-from", "--truth-depth-mm")
            }
            let calibration = try RecordedTrace(contentsOf: URL(fileURLWithPath: path))
            return try GainFit.fit(Replay.run(calibration, settings: settings), truthDepthMM: truthDepthMM).gain
        }
    }
}
