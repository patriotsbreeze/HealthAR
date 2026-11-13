import Foundation
import PlumbContracts
import Testing
@testable import PlumbSession

/// 14:02:10 on 14 March 2026, GMT. Every test session starts at this moment.
let fixtureStart = Date(timeIntervalSince1970: 1_773_496_930)

/// A compression whose stroke took a quarter of a second to reach its deepest point.
func stroke(_ index: Int, at tBottom: TimeInterval, depth: Double, interval: Double?,
            lock: LockState = .locked) -> Compression {
    Compression(index: index, tTop: tBottom - 0.25, tBottom: tBottom, depthMM: depth,
                intervalS: interval, lock: lock)
}

/// Log entries numbered 1, 2, 3 in the order given, the way a real log numbers them.
func numbered(_ items: [(t: TimeInterval, source: LogEntry.Source, body: LogEntry.Body)]) -> [LogEntry] {
    items.enumerated().map { index, item in
        LogEntry(id: index + 1, t: item.t, source: item.source, body: item.body)
    }
}

/// True when an optional number is there and within a hair of the expected one.
func isClose(_ value: Double?, _ expected: Double, tolerance: Double = 1e-9) -> Bool {
    guard let value else { return false }
    return abs(value - expected) <= tolerance
}

/// Asserts that a sentence was refused and that the reason names what was wrong.
func expectRefused(_ verdict: ScribeVerdict, mentioning fragment: String,
                   sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!verdict.accepted, "\"\(verdict.sentence.text)\" was accepted", sourceLocation: sourceLocation)
    #expect(verdict.reason?.contains(fragment) == true,
            "reason was: \(verdict.reason ?? "nil")", sourceLocation: sourceLocation)
}

/// Asserts that a sentence was accepted, and shows the reason when it was not.
func expectAccepted(_ verdict: ScribeVerdict, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(verdict.accepted, "\"\(verdict.sentence.text)\" was refused: \(verdict.reason ?? "nil")",
            sourceLocation: sourceLocation)
    #expect(verdict.reason == nil, sourceLocation: sourceLocation)
}
