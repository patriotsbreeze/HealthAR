import Foundation
import PlumbGeometry

/// What `plumb-replay` was asked to do, read from its command line.
public struct ReplayOptions: Sendable, Equatable {
    /// Where the gain comes from.
    public enum GainChoice: Sendable, Equatable {
        /// Heights as measured.
        case none
        /// Fit a gain on this trace and print it; the trace is then not scored.
        case fit
        /// A gain typed in, usually one printed by an earlier `--fit-gain` on another trace.
        case value(Double)
        /// Fit a gain on the trace at this path, then score this trace with it. Refused when the two are one recording.
        case fittedOn(path: String)
    }

    /// The trace to replay.
    public var tracePath: String
    /// The height method.
    public var method: HeightEstimator.Method
    /// The truth to score against, if any.
    public var truth: Truth
    /// Where the gain comes from.
    public var gain: GainChoice
    /// Replays with the range assumed instead of measured, next to the measured run for comparison.
    public var withoutRange: Bool
    /// The distance assumed with `withoutRange`, in metres.
    public var assumedRangeM: Double
    /// Where to write one line per compression, if anywhere.
    public var csvPath: String?

    /// Options with everything but the trace at its default.
    public init(tracePath: String, method: HeightEstimator.Method = .alongRay, truth: Truth = .init(),
                gain: GainChoice = .none, withoutRange: Bool = false,
                assumedRangeM: Double = ReplayOptions.defaultAssumedRangeM, csvPath: String? = nil) {
        self.tracePath = tracePath
        self.method = method
        self.truth = truth
        self.gain = gain
        self.withoutRange = withoutRange
        self.assumedRangeM = assumedRangeM
        self.csvPath = csvPath
    }

    /// The distance the capture side's defaults are tuned for, and so the honest guess for a phone that cannot measure it.
    public static let defaultAssumedRangeM = 1.0

    /// How to call the tool.
    public static let usage = """
        Usage: plumb-replay <trace.jsonl> [options]

        Replays a trace recorded on the phone through the same height estimator and compression
        analyzer the app runs, and prints what was counted.

          --method alongRay|imagePlane   height method (default alongRay; imagePlane with --no-range)
          --truth-depth-mm <mm>          the rig's known travel per push, to score depth against
          --truth-rate <per minute>      the rate pushed at, to score rate against
          --fit-gain                     fit a gain to --truth-depth-mm on this trace and print it;
                                         this trace is then not scored
          --gain <value>                 multiply every height by this gain, fitted on a different trace
          --gain-from <trace.jsonl>      fit the gain on that trace, then score this one with it
          --no-range                     also replay with no LiDAR range: the picture method with the
                                         hands assumed --assume-range-m away, next to the app's own
                                         along-ray LiDAR run; gains apply to the no-range run only
          --assume-range-m <m>           the distance assumed with --no-range (default 1.0)
          --csv <path>                   write one line per push to this file; never a trace given here
          --help                         show this
        """
}

/// What the command line asked for.
public enum ReplayRequest: Sendable, Equatable {
    /// Print the usage.
    case help
    /// Replay a trace.
    case replay(ReplayOptions)
}

extension ReplayOptions {
    /// Why a command line could not be read.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// A flag this tool does not know.
        case unknownFlag(String)
        /// A flag that needs a value came last.
        case missingValue(String)
        /// A flag's value is not one it takes.
        case badValue(flag: String, value: String)
        /// No trace was named, or more than one.
        case traceCount(Int)
        /// Two flags that cannot be used together.
        case conflict(String, String)
        /// A flag that needs another one that was not given.
        case needs(String, String)
        /// A flag that would write over a file this run reads.
        case overwrites(flag: String, path: String)

        /// The problem in plain words, with the usage after it.
        public var description: String {
            let problem: String
            switch self {
            case .unknownFlag(let flag): problem = "Unknown option \(flag)."
            case .missingValue(let flag): problem = "\(flag) needs a value."
            case .badValue(let flag, let value): problem = "\(flag) does not take \"\(value)\"."
            case .traceCount(0): problem = "Name one trace file to replay."
            case .traceCount(let count): problem = "Name one trace file to replay, not \(count)."
            case .conflict(let first, let second): problem = "\(first) and \(second) cannot be used together."
            case .needs(let flag, let other): problem = "\(flag) needs \(other)."
            case .overwrites(let flag, let path): problem = "\(flag) would write over \(path). Name another file."
            }
            return problem + "\n\n" + ReplayOptions.usage
        }
    }

    /// Reads the arguments after the program's name.
    public static func parse(_ arguments: [String]) throws -> ReplayRequest {
        var reader = ArgumentReader(arguments)
        var paths: [String] = []
        var method: HeightEstimator.Method?
        var truth = Truth()
        var gains: [(flag: String, choice: GainChoice)] = []
        var withoutRange = false
        var assumedRangeM: Double?
        var csvPath: String?

        while let argument = reader.next() {
            switch argument {
            case "--help", "-h":
                return .help
            case "--method":
                let value = try reader.value(for: argument)
                guard let chosen = methodNames[value] else { throw Failure.badValue(flag: argument, value: value) }
                method = chosen
            case "--truth-depth-mm":
                truth.depthMM = try reader.positive(for: argument)
            case "--truth-rate":
                truth.ratePerMin = try reader.positive(for: argument)
            case "--fit-gain":
                gains.append((argument, .fit))
            case "--gain":
                gains.append((argument, .value(try reader.positive(for: argument))))
            case "--gain-from":
                gains.append((argument, .fittedOn(path: try reader.value(for: argument))))
            case "--no-range":
                withoutRange = true
            case "--assume-range-m":
                assumedRangeM = try reader.positive(for: argument)
            case "--csv":
                csvPath = try reader.value(for: argument)
            default:
                guard !argument.hasPrefix("-") else { throw Failure.unknownFlag(argument) }
                paths.append(argument)
            }
        }

        guard paths.count == 1, let tracePath = paths.first else { throw Failure.traceCount(paths.count) }
        if gains.count > 1 { throw Failure.conflict(gains[0].flag, gains[1].flag) }
        let gain = gains.first?.choice ?? .none
        if gain == .fit || gains.first?.flag == "--gain-from", truth.depthMM == nil {
            throw Failure.needs(gains[0].flag, "--truth-depth-mm")
        }
        if assumedRangeM != nil, !withoutRange { throw Failure.needs("--assume-range-m", "--no-range") }
        if withoutRange, method == .alongRay { throw Failure.conflict("--no-range", "--method alongRay") }

        return .replay(ReplayOptions(
            tracePath: tracePath,
            method: method ?? (withoutRange ? .imagePlane : .alongRay),
            truth: truth, gain: gain, withoutRange: withoutRange,
            assumedRangeM: assumedRangeM ?? defaultAssumedRangeM, csvPath: csvPath))
    }

    /// The names `--method` takes: the estimator's own, and the same with a hyphen.
    private static let methodNames: [String: HeightEstimator.Method] = [
        "alongRay": .alongRay, "along-ray": .alongRay,
        "imagePlane": .imagePlane, "image-plane": .imagePlane,
    ]
}

/// Walks the arguments one at a time, taking a flag's value when it has one.
private struct ArgumentReader {
    private var remaining: ArraySlice<String>

    init(_ arguments: [String]) {
        remaining = arguments[...]
    }

    mutating func next() -> String? {
        remaining.popFirst()
    }

    /// The next argument, as the value `flag` takes. Another flag in its place means the value was left
    /// out: taken as a path it would quietly swallow that flag. A path that starts with a hyphen can be
    /// given as ./-name.
    mutating func value(for flag: String) throws -> String {
        guard let value = remaining.popFirst(), !value.hasPrefix("--"), value != "-h" else {
            throw ReplayOptions.Failure.missingValue(flag)
        }
        return value
    }

    /// A value that must be a finite number above zero.
    mutating func positive(for flag: String) throws -> Double {
        let text = try value(for: flag)
        guard let number = Double(text), number.isFinite, number > 0 else {
            throw ReplayOptions.Failure.badValue(flag: flag, value: text)
        }
        return number
    }
}
