import Foundation

public enum EvidenceSource: String, Sendable, Codable, CaseIterable {
    case timer, sensor, bystander
    case aiInferred = "ai_inferred"
    case system
}

public struct LogEntry: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case sessionStarted = "session_started"
        case stateEntered = "state_entered"
        case answer
        case finding
        case resourceSeen = "resource_seen"
        case breathMarked = "breath_marked"
        case callPrompted = "call_prompted"
        case coachingStarted = "coaching_started"
        case aedArrived = "aed_arrived"
        case padsOn = "pads_on"
        case shockMarked = "shock_marked"
        case patientMoved = "patient_moved"
        case emsArrived = "ems_arrived"
        case modelNote = "model_note"
        case proposalRejected = "proposal_rejected"
        case sentinelFlag = "sentinel_flag"
        case phrasePlayed = "phrase_played"
        case callChanged = "call_changed"
        case audioPaused = "audio_paused"
        /// A model report in an awake state. Detail is `kind,source,confidence`.
        case observation
        case flowEntered = "flow_entered"
        case aspirinAdvised = "aspirin_advised"
    }

    public struct Draft: Sendable, Equatable {
        public var kind: Kind
        public var source: EvidenceSource
        public var detail: String

        public init(kind: Kind, source: EvidenceSource, detail: String = "") {
            self.kind = kind
            self.source = source
            self.detail = detail
        }
    }

    public var seq: Int
    public var at: TimeInterval
    public var kind: Kind
    public var source: EvidenceSource
    public var detail: String
}

/// Append-only record of the session. The EMS card and caller script are built from this,
/// never from model transcripts.
public struct EventLog: Sendable, Equatable {
    public private(set) var entries: [LogEntry] = []

    public init() {}

    public mutating func append(_ drafts: [LogEntry.Draft], at time: TimeInterval) {
        for draft in drafts {
            entries.append(LogEntry(seq: entries.count, at: time, kind: draft.kind, source: draft.source, detail: draft.detail))
        }
    }

    public func ndjson() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try entries
            .map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n")
    }
}
