import Foundation
import PlumbContracts

extension WorkingTimeline {
    /// Builds the three rows from the session log, which is the only record there is.
    ///
    /// A tool call is assumed to be logged when it returns, so its span ends at the entry's time.
    /// The window covers the whole log. To show only a stretch of a long session, set `window` afterwards.
    /// - Parameters:
    ///   - sampleRate: how often the hands were measured, in plain words.
    ///   - cueWords: the plain words for a cue, such as "Push harder".
    ///   - toolWords: the plain words for a tool's name. Left alone, `plainWords` makes them.
    public init(log: [LogEntry], sampleRate: String, targets: Targets = .adult, cueWords: (Cue) -> String,
                toolWords: (String) -> String = WorkingTimeline.plainWords) {
        var strokes: [Stroke] = []
        var pauses: [Pause] = []
        var suggestions: [Suggestion] = []
        var decisions: [Decision] = []

        for entry in log {
            switch entry.body {
            case .compression(let compression):
                strokes.append(Stroke(t: compression.tBottom, bar: StrokeBar(compression, targets: targets)))
            case .pause(let start, let end):
                pauses.append(Pause(start: start, durationS: max(0, end - start)))
            case .toolCall(let name, let durationS, let ok, let summary):
                suggestions.append(Suggestion(id: entry.id, start: entry.t - durationS, durationS: durationS,
                                              name: toolWords(name), ok: ok, sentence: summary))
            case .cue(let cue):
                let words = cueWords(cue)
                let origin = entry.source == .rule ? ", chosen by a fixed rule" : ""
                decisions.append(Decision(id: entry.id, t: entry.t, label: words,
                                          sentence: "“\(words)” was spoken at \(Readout.elapsed(entry.t))\(origin)."))
            case .blocked(let what, let rule):
                decisions.append(Decision(id: entry.id, t: entry.t, label: what, refused: true, sentence: rule))
            case .found(let label, _, let accepted, let reason):
                decisions.append(Decision(id: entry.id, t: entry.t, label: label, refused: !accepted, sentence: reason))
            case .sessionStarted, .sessionEnded, .lock, .note:
                break
            }
        }

        let times = log.map(\.t) + suggestions.map(\.start)
        let start = times.min() ?? 0
        self.init(window: start...max(start, times.max() ?? 0), strokes: strokes, pauses: pauses,
                  sampleRate: sampleRate, suggestions: suggestions, decisions: decisions)
    }

    /// A tool's name as plain words: "read_depth" becomes "Read depth". An identifier is never shown as it is.
    public static func plainWords(_ name: String) -> String {
        let words = name.split { $0 == "_" || $0 == "-" || $0 == " " }.joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
