import Foundation
import Testing
@testable import PlumbReplay

/// The command line of `plumb-replay`.
@Suite struct OptionsTests {
    private func options(_ arguments: String) throws -> ReplayOptions {
        let words = arguments.split(separator: " ").map(String.init)
        guard case .replay(let options) = try ReplayOptions.parse(words) else {
            Issue.record("asked for help")
            return ReplayOptions(tracePath: "")
        }
        return options
    }

    private func failure(_ arguments: String) -> ReplayOptions.Failure? {
        do {
            _ = try ReplayOptions.parse(arguments.split(separator: " ").map(String.init))
            return nil
        } catch {
            return error as? ReplayOptions.Failure
        }
    }

    @Test func aTraceAloneIsReplayedAsThePhoneRunsIt() throws {
        let plain = try options("a.jsonl")
        #expect(plain == ReplayOptions(tracePath: "a.jsonl"))
        #expect(plain.method == .alongRay && plain.gain == .none && !plain.withoutRange)
        #expect(plain.truth.isEmpty && plain.csvPath == nil)
    }

    @Test func everyFlagIsRead() throws {
        let read = try options("--method imagePlane a.jsonl --truth-depth-mm 50 --truth-rate 110 --gain 1.04 --csv out.csv")
        #expect(read.tracePath == "a.jsonl")
        #expect(read.method == .imagePlane)
        #expect(read.truth == Truth(depthMM: 50, ratePerMin: 110))
        #expect(read.gain == .value(1.04))
        #expect(read.csvPath == "out.csv")
        #expect(try options("a.jsonl --method along-ray").method == .alongRay)
        #expect(try options("a.jsonl --method image-plane").method == .imagePlane)
    }

    @Test func fittingAndCalibratingElsewhereBothNeedTheTrueDepth() throws {
        #expect(try options("a.jsonl --fit-gain --truth-depth-mm 50").gain == .fit)
        #expect(try options("b.jsonl --gain-from a.jsonl --truth-depth-mm 50").gain == .fittedOn(path: "a.jsonl"))
        #expect(failure("a.jsonl --fit-gain") == .needs("--fit-gain", "--truth-depth-mm"))
        #expect(failure("b.jsonl --gain-from a.jsonl --truth-rate 110") == .needs("--gain-from", "--truth-depth-mm"))
    }

    @Test func onlyOneSourceOfGain() {
        #expect(failure("a.jsonl --truth-depth-mm 50 --fit-gain --gain 1.1") == .conflict("--fit-gain", "--gain"))
        #expect(failure("a.jsonl --gain 1.1 --gain-from b.jsonl") == .conflict("--gain", "--gain-from"))
    }

    @Test func withoutTheRangeThePictureMethodIsTheOnlyOne() throws {
        let stripped = try options("a.jsonl --no-range")
        #expect(stripped.withoutRange && stripped.method == .imagePlane)
        #expect(stripped.assumedRangeM == ReplayOptions.defaultAssumedRangeM)
        #expect(try options("a.jsonl --no-range --assume-range-m 0.7").assumedRangeM == 0.7)
        #expect(failure("a.jsonl --no-range --method alongRay") == .conflict("--no-range", "--method alongRay"))
        #expect(failure("a.jsonl --assume-range-m 0.7") == .needs("--assume-range-m", "--no-range"))
    }

    @Test func badCommandLinesSayWhatIsWrong() {
        #expect(failure("") == .traceCount(0))
        #expect(failure("a.jsonl b.jsonl") == .traceCount(2))
        #expect(failure("a.jsonl --speed 2") == .unknownFlag("--speed"))
        #expect(failure("a.jsonl --truth-depth-mm") == .missingValue("--truth-depth-mm"))
        #expect(failure("a.jsonl --truth-depth-mm deep") == .badValue(flag: "--truth-depth-mm", value: "deep"))
        #expect(failure("a.jsonl --gain 0") == .badValue(flag: "--gain", value: "0"))
        #expect(failure("a.jsonl --gain -1") == .badValue(flag: "--gain", value: "-1"))
        #expect(failure("a.jsonl --gain nan") == .badValue(flag: "--gain", value: "nan"))
        #expect(failure("a.jsonl --method sideways") == .badValue(flag: "--method", value: "sideways"))
    }

    /// A flag where a value should be is never taken as the value: the value is missing.
    @Test func aFlagIsNeverTakenAsTheValueOfTheOneBefore() throws {
        #expect(failure("a.jsonl --csv --no-range") == .missingValue("--csv"))
        #expect(failure("--gain-from --truth-depth-mm 50 a.jsonl") == .missingValue("--gain-from"))
        #expect(failure("a.jsonl --method --help") == .missingValue("--method"))
        #expect(failure("a.jsonl --csv -h") == .missingValue("--csv"))
        #expect(failure("a.jsonl --truth-depth-mm --fit-gain") == .missingValue("--truth-depth-mm"))
        // A path starting with a hyphen goes in as ./-name.
        #expect(try options("a.jsonl --csv ./-pushes.csv").csvPath == "./-pushes.csv")
    }

    @Test func helpIsAskedFor() throws {
        #expect(try ReplayOptions.parse(["--help"]) == .help)
        #expect(try ReplayOptions.parse(["a.jsonl", "-h"]) == .help)
    }

    /// The message names the problem first and then shows how the tool is called.
    @Test func aFailureReadsAsPlainWordsAndTheUsage() {
        let text = ReplayOptions.Failure.needs("--fit-gain", "--truth-depth-mm").description
        #expect(text.hasPrefix("--fit-gain needs --truth-depth-mm."))
        #expect(text.hasSuffix(ReplayOptions.usage))
    }
}
