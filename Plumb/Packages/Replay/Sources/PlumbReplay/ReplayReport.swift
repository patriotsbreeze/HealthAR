import Foundation
import PlumbContracts
import PlumbGeometry

/// What `plumb-replay` prints and writes, built from finished replays.
public struct ReplayReport: Sendable {
    /// The file name shown at the top.
    public var traceName: String
    /// The trace's own description of itself.
    public var header: TraceHeader
    /// The replays to show side by side: one, or the measured range then the assumed one.
    public var runs: [ReplayResult]
    /// What the runs were scored against.
    public var truth: Truth
    /// One score per run, in the same order; empty when nothing was scored.
    public var scores: [TruthReport]
    /// The gain fitted on this trace, when it was asked for. The trace is then not scored.
    public var fitted: FittedGain?

    /// A report of finished replays.
    public init(traceName: String, header: TraceHeader, runs: [ReplayResult], truth: Truth = .init(),
                scores: [TruthReport] = [], fitted: FittedGain? = nil) {
        self.traceName = traceName
        self.header = header
        self.runs = runs
        self.truth = truth
        self.scores = scores
        self.fitted = fitted
    }

    /// The plain text to print.
    public var text: String {
        var blocks = [about]
        // One run gets its pushes listed; a side-by-side comparison leaves them to the CSV.
        if runs.count == 1, let run = runs.first { blocks.append(strokeTable(run)) }
        blocks.append(summaryTable)
        if let fitted {
            blocks.append(gainNote(fitted))
        } else if !scores.isEmpty {
            blocks.append(truthTables)
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// One line per push of every run, for a spreadsheet.
    public var csv: String {
        var lines = ["run,index,bottom_s,depth_mm,interval_s,trust,reported_s"]
        for run in runs {
            for row in run.strokes {
                lines.append([Self.csvName(run.range), "\(row.index)", Figure.fixed(row.t, 3),
                              Figure.fixed(row.depthMM, 2), row.intervalS.map { Figure.fixed($0, 3) } ?? "",
                              Self.trustWords(row.lock), Figure.fixed(row.reportedAt, 3)].joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Blocks

    private var about: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        var lines = [("Trace", "\(traceName)  (\(runs.first?.traceFingerprint.value ?? "-"))"),
                     ("Recorded", "\(formatter.string(from: header.createdAt)) on \(header.device)")]
        if !header.note.isEmpty { lines.append(("Note", header.note)) }
        if let run = runs.first {
            let seconds = run.span.map { $0.upperBound - $0.lowerBound }
            lines.append(("Frames", "\(run.frameCount) over \(Figure.fixed(seconds, 1)) s, "
                + "hands box placed again \(run.placementCount) times"))
        }
        for run in runs {
            lines.append(("Heights", "\(Self.methodWords(run.method)), \(Self.rangeWords(run.range))"
                + (run.gain.value == 1 ? "" : ", gain \(Figure.fixed(run.gain.value, 3))")))
        }
        let width = (lines.map(\.0.count).max() ?? 0) + 2
        return lines.map { $0.0.padding(toLength: width, withPad: " ", startingAt: 0) + $0.1 }
            .joined(separator: "\n")
    }

    private func strokeTable(_ run: ReplayResult) -> String {
        var table = TextTable(["#", "bottom s", "depth mm", "interval s", "trust", "delay s"], wordColumns: [4])
        for row in run.strokes {
            table.add(["\(row.index)", Figure.fixed(row.t, 3), Figure.fixed(row.depthMM, 1),
                       Figure.fixed(row.intervalS, 3), Self.trustWords(row.lock), Figure.fixed(row.delayS, 3)])
        }
        return run.strokes.isEmpty ? "No pushes counted." : table.text
    }

    private var summaryTable: String {
        let summaries = runs.map(\.summary)
        var table = TextTable([""] + runs.map { Self.columnName($0.range) })
        func row(_ label: String, _ value: (ReplayResult, ReplaySummary) -> String) {
            table.add([label] + zip(runs, summaries).map(value))
        }
        row("frames with a height") { run, _ in "\(run.sampleCount) of \(run.frameCount)" }
        row("pushes counted") { _, s in "\(s.count)" }
        row("of them locked") { _, s in "\(s.lockedCount)" }
        row("rate a minute") { _, s in Figure.fixed(s.ratePerMin, 1) }
        row("depth median mm") { _, s in Figure.fixed(s.depthMedianMM, 1) }
        row("depth spread mm, middle half") { _, s in Figure.fixed(s.depthSpreadMM, 1) }
        row("time locked") { _, s in Figure.percent(s.lockedShare) }
        row("delay to report s, median") { _, s in Figure.fixed(s.delayMedianS, 3) }
        row("delay to report s, longest") { _, s in Figure.fixed(s.delayLongestS, 3) }
        row("hands range m, median") { _, s in Figure.fixed(s.rangeMedianM, 2) }
        return table.text
    }

    private var truthTables: String {
        var parts = [truthLine]
        for (run, score) in zip(runs, scores) {
            var table = TextTable([Self.columnName(run.range), "n", "median abs error", "bias", "lowest", "highest"])
            func add(_ label: String, _ stats: ErrorStats?) {
                guard let stats else { return }
                table.add(["  " + label, "\(stats.n)", Figure.fixed(stats.medianAbsoluteError, 1),
                           Figure.signed(stats.bias, 1), Figure.signed(stats.lowest, 1), Figure.signed(stats.highest, 1)])
            }
            add("depth, locked mm", score.depthLocked)
            add("depth, all mm", score.depthAll)
            add("rate a minute", score.rate)
            parts.append(table.rows.isEmpty ? "\(Self.columnName(run.range)): nothing to score." : table.text)
        }
        return parts.joined(separator: "\n\n")
    }

    private var truthLine: String {
        let known = [truth.depthMM.map { "\(Figure.fixed($0, 1)) mm a push" },
                     truth.ratePerMin.map { "\(Figure.fixed($0, 0)) a minute" }].compactMap { $0 }
        return "Against the truth: " + known.joined(separator: ", ")
    }

    /// The fitted gain and how to use it. Beside a yardstick run, it belongs to the last run, the one asked for.
    private func gainNote(_ fitted: FittedGain) -> String {
        let value = Figure.fixed(fitted.gain.value, 3)
        let which = runs.count > 1 ? runs.last.map { " for the \(Self.columnName($0.range)) run" } ?? "" : ""
        return """
            Gain \(value)\(which), fitted to \(Figure.fixed(fitted.truthDepthMM, 1)) mm from \(fitted.strokeCount) \
            locked pushes with median \(Figure.fixed(fitted.medianDepthMM, 1)) mm.
            This recording set the gain, so it is not scored. Score a different recording with \
            \(runs.last.map(Self.sameRunFlags) ?? "")--gain \(value).
            """
    }

    /// The flags that repeat a run's method and range on another recording, each followed by a space.
    static func sameRunFlags(_ run: ReplayResult) -> String {
        switch run.range {
        case .measured:
            return run.method == .alongRay ? "" : "--method \(run.method.rawValue) "
        case .assumed(let metres):
            let distance = metres == ReplayOptions.defaultAssumedRangeM ? "" : "--assume-range-m \(metres) "
            return "--no-range " + distance
        }
    }

    // MARK: - Words

    static func methodWords(_ method: HeightEstimator.Method) -> String {
        switch method {
        case .alongRay: "along the line of sight"
        case .imagePlane: "picture slide"
        }
    }

    static func rangeWords(_ range: RangeSource) -> String {
        switch range {
        case .measured: "LiDAR range"
        case .assumed(let metres): "no LiDAR, hands assumed \(Figure.fixed(metres, 2)) m away"
        }
    }

    static func columnName(_ range: RangeSource) -> String {
        switch range {
        case .measured: "LiDAR range"
        case .assumed(let metres): "assumed \(Figure.fixed(metres, 2)) m"
        }
    }

    static func csvName(_ range: RangeSource) -> String {
        switch range {
        case .measured: "measured"
        case .assumed: "assumed"
        }
    }

    static func trustWords(_ lock: LockState) -> String {
        switch lock {
        case .locked: "locked"
        case .estimating: "estimating"
        case .rateOnly: "rate only"
        case .lost: "lost"
        }
    }
}
