import Foundation
import PlumbContracts

/// A stretch of a session as the show-working screen draws it: three rows on one time axis.
public struct WorkingTimeline: Equatable, Sendable {
    /// One measured push and when its deepest point was.
    public struct Stroke: Equatable, Sendable {
        /// Seconds since the session started.
        public var t: TimeInterval
        /// The push as the bars draw it.
        public var bar: StrokeBar

        /// A push at a time.
        public init(t: TimeInterval, bar: StrokeBar) {
            self.t = t
            self.bar = bar
        }
    }

    /// A stretch with no pushes.
    public struct Pause: Equatable, Sendable {
        /// Seconds since the session started.
        public var start: TimeInterval
        /// How long it lasted, in seconds.
        public var durationS: Double

        /// A pause from when it began and how long it lasted.
        public init(start: TimeInterval, durationS: Double) {
            self.start = start
            self.durationS = durationS
        }
    }

    /// One tool call a model made. Drawn as a span; never trusted on its own.
    public struct Suggestion: Equatable, Sendable, Identifiable {
        /// What selects it. Unique among suggestions.
        public var id: Int
        /// When the call began, in seconds since the session started.
        public var start: TimeInterval
        /// How long the call took, in seconds.
        public var durationS: Double
        /// The tool's name as it should be read.
        public var name: String
        /// False when the call failed. A failed call is drawn as an outline.
        public var ok: Bool
        /// One plain sentence shown when this span is selected.
        public var sentence: String

        /// A tool call from plain values.
        public init(id: Int, start: TimeInterval, durationS: Double, name: String, ok: Bool = true, sentence: String) {
            self.id = id
            self.start = start
            self.durationS = durationS
            self.name = name
            self.ok = ok
            self.sentence = sentence
        }
    }

    /// One thing the fixed rules decided: a cue that was spoken, or something that was refused.
    public struct Decision: Equatable, Sendable, Identifiable {
        /// What selects it. Unique among decisions.
        public var id: Int
        /// When it was decided, in seconds since the session started.
        public var t: TimeInterval
        /// A few plain words, such as "Push harder".
        public var label: String
        /// True when the rules refused it. Drawn struck through.
        public var refused: Bool
        /// One plain sentence shown when this mark is selected.
        public var sentence: String

        /// A decision from plain values.
        public init(id: Int, t: TimeInterval, label: String, refused: Bool = false, sentence: String) {
            self.id = id
            self.t = t
            self.label = label
            self.refused = refused
            self.sentence = sentence
        }
    }

    /// The seconds of the session the rows cover. Narrow it to show the last stretch of a long session.
    public var window: ClosedRange<TimeInterval>
    /// The "Measured" row: every push in the window.
    public var strokes: [Stroke]
    /// The pauses in the window, drawn in the "Measured" row.
    public var pauses: [Pause]
    /// How often the hands were measured, in plain words such as "60 a second".
    public var sampleRate: String
    /// The "Suggested" row.
    public var suggestions: [Suggestion]
    /// The "Decided" row.
    public var decisions: [Decision]

    /// A timeline from plain values.
    public init(window: ClosedRange<TimeInterval>, strokes: [Stroke], pauses: [Pause] = [], sampleRate: String,
                suggestions: [Suggestion] = [], decisions: [Decision] = []) {
        self.window = window
        self.strokes = strokes
        self.pauses = pauses
        self.sampleRate = sampleRate
        self.suggestions = suggestions
        self.decisions = decisions
    }

    /// The timeline with everything outside its window left out. A pause or a span that straddles
    /// an edge is kept whole, so its length still reads true; the layout cuts its drawing at the edge.
    var visible: WorkingTimeline {
        func overlapsWindow(_ start: TimeInterval, _ durationS: Double) -> Bool {
            window.overlaps(start...(start + max(0, durationS)))
        }
        var shown = self
        shown.strokes = strokes.filter { window.contains($0.t) }
        shown.pauses = pauses.filter { overlapsWindow($0.start, $0.durationS) }
        shown.suggestions = suggestions.filter { overlapsWindow($0.start, $0.durationS) }
        shown.decisions = decisions.filter { window.contains($0.t) }
        return shown
    }

    /// The one sentence for a selected mark, or nil when the selection is not in this timeline.
    public func sentence(for selection: WorkingSelection) -> String? {
        switch selection {
        case .suggestion(let id): suggestions.first { $0.id == id }?.sentence
        case .decision(let id): decisions.first { $0.id == id }?.sentence
        }
    }
}

/// Which mark on the show-working screen is selected.
public enum WorkingSelection: Hashable, Sendable {
    /// The suggestion with this id.
    case suggestion(Int)
    /// The decision with this id.
    case decision(Int)
}

/// One number of the scoreboard, already formatted, with the words that say what it counts.
public struct WorkingScore: Equatable, Sendable {
    /// The number as it should be read, such as "97%".
    public var value: String
    /// What it counts, in a few plain words.
    public var caption: String

    /// A score from its number and its words.
    public init(value: String, caption: String) {
        self.value = value
        self.caption = caption
    }
}
