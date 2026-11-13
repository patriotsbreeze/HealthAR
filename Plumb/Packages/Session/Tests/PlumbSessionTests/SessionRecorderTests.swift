import Foundation
import PlumbContracts
import Testing
@testable import PlumbSession

@Suite struct SessionRecorderTests {
    @Test func startsWithTheSessionStartAtTimeZero() {
        let recorder = SessionRecorder(startedWallClock: fixtureStart)
        #expect(recorder.log.entries == [
            LogEntry(id: 1, t: 0, source: .system, body: .sessionStarted(wallClock: fixtureStart)),
        ])
    }

    @Test func aScriptedRunProducesTheExpectedEntries() {
        let first = stroke(1, at: 1.0, depth: 41, interval: nil)
        let second = stroke(2, at: 1.5, depth: 52, interval: 0.5)
        let third = stroke(3, at: 9.5, depth: 55, interval: nil, lock: .estimating)

        var recorder = SessionRecorder(startedWallClock: fixtureStart)
        recorder.record([.lockChanged(.locked, at: 0.5), .compression(first), .compression(second)])
        recorder.record(cue: .pushHarder, at: 1.75)
        recorder.record([.pauseStarted(at: 1.5)])
        recorder.record([.lockChanged(.estimating, at: 9.25), .pauseEnded(at: 9.5, duration: 8),
                         .compression(third)])
        recorder.record(t: 10, source: .tapped, body: .note("crew arrived"))
        recorder.end(at: 20, openPauseSince: 9.5)

        #expect(recorder.log.entries == [
            LogEntry(id: 1, t: 0, source: .system, body: .sessionStarted(wallClock: fixtureStart)),
            LogEntry(id: 2, t: 0.5, source: .measured, body: .lock(.locked)),
            LogEntry(id: 3, t: 1.0, source: .measured, body: .compression(first)),
            LogEntry(id: 4, t: 1.5, source: .measured, body: .compression(second)),
            LogEntry(id: 5, t: 1.75, source: .rule, body: .cue(.pushHarder)),
            LogEntry(id: 6, t: 9.25, source: .measured, body: .lock(.estimating)),
            LogEntry(id: 7, t: 9.5, source: .measured, body: .pause(start: 1.5, end: 9.5)),
            LogEntry(id: 8, t: 9.5, source: .measured, body: .compression(third)),
            LogEntry(id: 9, t: 10, source: .tapped, body: .note("crew arrived")),
            LogEntry(id: 10, t: 20, source: .measured, body: .pause(start: 9.5, end: 20)),
            LogEntry(id: 11, t: 20, source: .system, body: .sessionEnded),
        ])
    }

    @Test func aPauseStartAloneWritesNothing() {
        var recorder = SessionRecorder(startedWallClock: fixtureStart)
        recorder.record([.pauseStarted(at: 4)])
        #expect(recorder.log.entries.count == 1)
    }

    @Test func endingWithNoOpenPauseWritesOnlyTheEnd() {
        var recorder = SessionRecorder(startedWallClock: fixtureStart)
        recorder.record([.compression(stroke(1, at: 2, depth: 50, interval: nil))])
        recorder.end(at: 3, openPauseSince: nil)

        #expect(recorder.log.entries.count == 3)
        #expect(recorder.log.entries.last == LogEntry(id: 3, t: 3, source: .system, body: .sessionEnded))
    }

    @Test func endingTwiceWritesOneEnd() {
        var recorder = SessionRecorder(startedWallClock: fixtureStart)
        recorder.end(at: 3, openPauseSince: 1)
        recorder.end(at: 9, openPauseSince: 1)

        #expect(recorder.log.entries.map(\.body) == [
            .sessionStarted(wallClock: fixtureStart), .pause(start: 1, end: 3), .sessionEnded,
        ])
    }

    @Test func aPauseWithNoLengthIsNotWritten() {
        var recorder = SessionRecorder(startedWallClock: fixtureStart)
        recorder.record([.pauseEnded(at: 5, duration: 0), .pauseEnded(at: 6, duration: -2),
                         .pauseEnded(at: 7, duration: .nan)])
        recorder.end(at: 8, openPauseSince: 8)

        #expect(recorder.log.entries.map(\.body) == [.sessionStarted(wallClock: fixtureStart), .sessionEnded])
    }

    @Test func aCompressionReportedLateKeepsItsOwnTimes() {
        var recorder = SessionRecorder(startedWallClock: fixtureStart)
        let late = stroke(1, at: 4.0, depth: 50, interval: nil)
        recorder.record(cue: .pushNow, at: 4.2)
        recorder.record([.compression(late)])

        let entry = recorder.log.entries[2]
        // The log's own clock never goes back, but the measurement inside is untouched.
        #expect(entry.t == 4.2)
        #expect(entry.body == .compression(late))
    }

    @Test func factsCanStillBeAddedAfterTheEnd() {
        var recorder = SessionRecorder(startedWallClock: fixtureStart)
        recorder.end(at: 30, openPauseSince: nil)
        recorder.record(t: 31, source: .rule, body: .blocked(what: "a sentence", rule: "It cites no log entries."))

        #expect(recorder.log.entries.map(\.id) == [1, 2, 3])
        #expect(recorder.log.entries.last?.source == .rule)
    }
}
