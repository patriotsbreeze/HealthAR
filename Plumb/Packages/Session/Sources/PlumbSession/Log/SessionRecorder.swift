import Foundation
import PlumbContracts

/// Writes what the analyzer and the coach report into a session log, each fact with its source.
public struct SessionRecorder: Sendable {
    /// The record so far. It starts with one `sessionStarted` entry at time 0.
    public private(set) var log: SessionLog
    private var hasEnded = false

    /// Starts a record. `startedWallClock` is the clock time at session time 0.
    public init(startedWallClock: Date) {
        log = SessionLog()
        log.append(t: 0, source: .system, body: .sessionStarted(wallClock: startedWallClock))
    }

    /// Records what the analyzer noticed, as measured facts.
    /// A pause is written once, as a whole, when it ends; its start alone writes nothing.
    public mutating func record(_ events: [SignalEvent]) {
        for event in events {
            switch event {
            case .compression(let stroke):
                log.append(t: stroke.tBottom, source: .measured, body: .compression(stroke))
            case .pauseStarted:
                break
            case .pauseEnded(let end, let duration):
                writePause(start: end - duration, end: end)
            case .lockChanged(let state, let t):
                log.append(t: t, source: .measured, body: .lock(state))
            }
        }
    }

    /// Records that the coach spoke a cue, as a decision made by a fixed rule.
    public mutating func record(cue: Cue, at t: TimeInterval) {
        log.append(t: t, source: .rule, body: .cue(cue))
    }

    /// Records any other fact, with the source the caller names.
    public mutating func record(t: TimeInterval, source: LogEntry.Source, body: LogEntry.Body) {
        log.append(t: t, source: source, body: body)
    }

    /// Closes the session at `t`. A pause still open (running since `openPauseSince`) is written
    /// first, ending at `t`. A second call does nothing, so the log holds one `sessionEnded`.
    public mutating func end(at t: TimeInterval, openPauseSince: TimeInterval?) {
        guard !hasEnded else { return }
        hasEnded = true
        if let start = openPauseSince {
            writePause(start: start, end: t)
        }
        log.append(t: t, source: .system, body: .sessionEnded)
    }

    /// A pause with no length, or with a time that is not a number, is not a pause and is not written.
    private mutating func writePause(start: TimeInterval, end: TimeInterval) {
        guard start.isFinite, end.isFinite, end > start else { return }
        log.append(t: end, source: .measured, body: .pause(start: max(0, start), end: end))
    }
}
