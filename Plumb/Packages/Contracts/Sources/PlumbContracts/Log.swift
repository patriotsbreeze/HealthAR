import Foundation

/// One line of the session record. Append-only. The handoff is computed from these and nothing else.
public struct LogEntry: Sendable, Codable, Equatable, Identifiable {
    /// 1 for the first entry. Never reused.
    public var id: Int
    /// Seconds since the session started.
    public var t: TimeInterval
    public var source: Source
    public var body: Body

    public init(id: Int, t: TimeInterval, source: Source, body: Body) {
        self.id = id
        self.t = t
        self.source = source
        self.body = body
    }

    /// Where a fact came from. Shown to people as a plain word.
    public enum Source: String, Sendable, Codable, CaseIterable {
        /// A sensor measured it.
        case measured
        /// A person tapped it.
        case tapped
        /// A person said it.
        case said
        /// A model suggested it. Never trusted on its own.
        case model
        /// A fixed rule decided it.
        case rule
        /// The app itself (start, stop, connection).
        case system
    }

    public enum Body: Sendable, Codable, Equatable {
        case sessionStarted(wallClock: Date)
        case sessionEnded
        case compression(Compression)
        /// A finished pause. `start` is the last compression before it, `end` the first after it.
        case pause(start: TimeInterval, end: TimeInterval)
        case lock(LockState)
        /// A cue was spoken.
        case cue(Cue)
        /// A model called a tool. `summary` is one plain sentence.
        case toolCall(name: String, durationS: Double, ok: Bool, summary: String)
        /// Something was refused. `rule` is one plain sentence saying why.
        case blocked(what: String, rule: String)
        /// A model pointed at an object and the sensors tested it.
        case found(label: String, distanceM: Double?, accepted: Bool, reason: String)
        case note(String)
    }
}
