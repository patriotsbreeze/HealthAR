import Foundation
import PlumbContracts
@testable import PlumbUI

/// The demo session as a log, and the show-working inputs built from it.
@MainActor
enum WorkingFixture {
    static let cueWords: (Cue) -> String = { cue in
        switch cue {
        case .pushNow: "Push now"
        case .pushHarder: "Push harder"
        case .faster: "Faster"
        case .slower: "Slower"
        case .good: "Good"
        }
    }

    /// The id of the first cue in `log`, used as the opening selection.
    static let firstCueID = 1000

    static var log: [LogEntry] {
        let strokes = Fixture.strokes(SyntheticSession.demo)
        var entries: [LogEntry] = strokes.enumerated().map { index, stroke in
            let compression = Compression(index: index + 1, tTop: stroke.t - 0.2, tBottom: stroke.t,
                                          depthMM: stroke.bar.depthMM, intervalS: nil, lock: .locked)
            return LogEntry(id: index + 1, t: stroke.t, source: .measured, body: .compression(compression))
        }
        entries += [
            LogEntry(id: firstCueID, t: 4.8, source: .rule, body: .cue(.pushHarder)),
            LogEntry(id: 1001, t: 9.4, source: .model,
                     body: .toolCall(name: "read_depth", durationS: 0.6, ok: true,
                                     summary: "A model read the last ten depths to answer a spoken question.")),
            LogEntry(id: 1002, t: 13.6, source: .rule, body: .cue(.good)),
            LogEntry(id: 1003, t: 17.2, source: .rule,
                     body: .blocked(what: "Stop compressions",
                                    rule: "A model may never tell the rescuer to stop; only a person can end the rescue.")),
            LogEntry(id: 1004, t: 20.5, source: .measured, body: .pause(start: 20.4, end: 25.7)),
            LogEntry(id: 1005, t: 23.1, source: .rule, body: .cue(.pushNow)),
            LogEntry(id: 1006, t: 29.6, source: .model,
                     body: .toolCall(name: "find_aed", durationS: 2.1, ok: true,
                                     summary: "A model looked through the camera for an AED sign.")),
            LogEntry(id: 1007, t: 30.4, source: .rule, body: .cue(.good)),
            LogEntry(id: 1008, t: 37.5, source: .system, body: .sessionEnded),
        ]
        entries.insert(LogEntry(id: 0, t: 0, source: .system, body: .sessionStarted(wallClock: Fixture.now)), at: 0)
        return entries.sorted { $0.t < $1.t }
    }

    /// The plain words for each tool the made-up model called.
    static let toolWords: (String) -> String = { name in
        name == "find_aed" ? "Find AED" : WorkingTimeline.plainWords(name)
    }

    static var timeline: WorkingTimeline {
        WorkingTimeline(log: log, sampleRate: "60 a second", cueWords: cueWords, toolWords: toolWords)
    }

    static let scores = [
        WorkingScore(value: "97%", caption: "of pushes matched a hand count"),
        WorkingScore(value: "3 mm", caption: "typical error against a ruler"),
        WorkingScore(value: "0", caption: "cues chosen by a model"),
    ]

    static let failsWhen = [
        "The hands leave the picture.",
        "Loose sleeves hide the wrists.",
        "The phone is knocked or moved.",
        "Direct sun washes out the depth sensor.",
    ]
}
