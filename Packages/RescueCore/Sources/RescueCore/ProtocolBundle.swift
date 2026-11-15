import Foundation

/// The clinical protocol and phrases, loaded from `clinical/`. Marked DRAFT until reviewed.
public struct ProtocolBundle: Sendable, Equatable {
    public var definition: ProtocolDefinition
    public var phrases: PhraseFile
    public var flows: [ScenarioModule.Flow] = []
    public var knowledgePack: KnowledgePack?
    /// Corrections for awake states, kept apart so none can resolve on the arrest path.
    public var awakeCorrectionPhrases: [String: String] = [:]
    /// Resource hints for awake states, kept apart for the same reason.
    public var awakeResourceHints: [String: String] = [:]
    /// What `merging` refused, for the operator panel.
    public var moduleFailures: [ModuleFailure] = []

    public init(protocolData: Data, phrasesData: Data) throws {
        let decoder = Self.clinicalDecoder()
        definition = try decoder.decode(ProtocolDefinition.self, from: protocolData)
        phrases = try decoder.decode(PhraseFile.self, from: phrasesData)
    }

    static func clinicalDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    public func text(forPhrase id: String) -> String? {
        phrases.phrases.first { $0.id == id }?.text
    }
}

public struct PhraseFile: Sendable, Equatable, Codable {
    public struct Phrase: Sendable, Equatable, Codable {
        public var id: String
        public var text: String
        public var citation: String
    }

    public var version: String
    public var status: String
    public var reviewer: String?
    public var phrases: [Phrase]
}

public struct ProtocolDefinition: Sendable, Equatable, Codable {
    public struct SpeechGateTable: Sendable, Equatable, Codable {
        /// The one table that decides where model voice is audible. Empty closes it everywhere.
        public var openStates: [String]
    }

    public var version: String
    public var status: String
    public var reviewer: String?
    public var initialState: String
    public var speechGate: SpeechGateTable
    public var resourceHints: [String: String]
    public var correctionPhrases: [String: String]
    public var loweringReportPhrase: String
    /// A transition can make queued phrases stale, but never these, which must be heard once.
    public var keepQueuedPhrases: [String]
    public var audioPauseSeconds: TimeInterval
    public var modelSpeechHoldSeconds: TimeInterval
    /// How long the mic stays closed after a dispatcher is reported as audible.
    public var dispatcherMicHoldSeconds: TimeInterval
    public var states: [StateDefinition]
}

public struct StateDefinition: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case intake, watch, setup, cpr, card, triage, flow

        /// The model can't move the rescue out of these, whatever the urgency says.
        public var isArrestPath: Bool {
            switch self {
            case .intake, .watch, .setup, .cpr: true
            case .card, .triage, .flow: false
            }
        }

        /// A person has tapped that the patient is awake.
        public var isAwake: Bool { self == .triage || self == .flow }

        /// Nil for a card, which keeps whatever session is running.
        public var liveMode: LiveMode? {
            if isAwake { return .awake }
            return isArrestPath ? .arrest : nil
        }
    }

    public enum MetronomeRule: String, Sendable, Codable { case on, off }

    public enum Question: String, Sendable, Codable {
        case responsive, breathing
        case aspirinRiskReported = "aspirin_risk_reported"
        case dangerSigns = "danger_signs"
        case canCoughOrSpeak = "can_cough_or_speak"
    }

    public struct BreathGuard: Sendable, Equatable, Codable {
        public var count: Int
        public var to: String
    }

    public struct Timeout: Sendable, Equatable, Codable {
        public var seconds: TimeInterval
        public var to: String
        public var ifBreathsAtLeast: BreathGuard?
        /// Played before the target's entry phrases, for what silence itself decided.
        public var phrases: [String]?
    }

    public struct Transition: Sendable, Equatable, Codable {
        public var on: String
        public var to: String
        /// Played in order, before the target state's entry phrases.
        public var phrases: [String]?
        public var log: LogEntry.Kind?
        /// A model report below this stays on the record and moves nothing.
        public var minConfidence: Confidence?
        /// Silences the phrase lane at once, for a collapse that can't wait out a sentence.
        public var cutsPhrases: Bool

        private enum CodingKeys: String, CodingKey {
            case on, to, phrases, log, minConfidence, cutsPhrases
        }

        init(on: String, to: String, phrases: [String]? = nil, log: LogEntry.Kind? = nil, cutsPhrases: Bool = false) {
            self.on = on
            self.to = to
            self.phrases = phrases
            self.log = log
            self.cutsPhrases = cutsPhrases
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            on = try c.decode(String.self, forKey: .on)
            to = try c.decode(String.self, forKey: .to)
            phrases = try c.decodeIfPresent([String].self, forKey: .phrases)
            log = try c.decodeIfPresent(LogEntry.Kind.self, forKey: .log)
            minConfidence = try c.decodeIfPresent(Confidence.self, forKey: .minConfidence)
            cutsPhrases = try c.decodeIfPresent(Bool.self, forKey: .cutsPhrases) ?? false
        }
    }

    public struct RepeatingPrompt: Sendable, Equatable, Codable {
        public var phrase: String
        public var everySeconds: TimeInterval
    }

    /// A static card drawn on a step. It uses no camera or frames, and gates nothing.
    public enum Guide: String, Sendable, Codable {
        case sitRest = "sit_rest"
        case supportLimb = "support_limb"
        case backBlows = "back_blows"
        case abdominalThrusts = "abdominal_thrusts"
    }

    public var id: String
    public var kind: Kind
    public var urgency: Int
    /// The condition this state treats, when it's part of one.
    public var flow: String?
    /// Entered instead of this state once pads are on, when the AED stays the authority.
    public var afterPads: String?
    public var question: Question?
    public var logOnEnter: LogEntry.Kind?
    public var entryPhrases: [String]
    public var metronome: MetronomeRule
    public var metronomeToggleable: Bool
    public var frameUplink: Bool
    public var overlay: OverlayTarget?
    public var guide: Guide?
    public var allowsPpg: Bool
    public var allowedSay: [String]
    public var repeating: [RepeatingPrompt]
    public var timeout: Timeout?
    public var transitions: [Transition]
    public var citation: String
    /// What the step points at on the body or in the room. Only a module's states may carry these.
    public var cues: [Cue]
    /// Single frozen frames may go to the one-shot locator here, to find the flow's materials. The
    /// Live session still sees only what `frame_uplink` opens.
    public var locateMaterials: Bool

    private enum CodingKeys: String, CodingKey {
        case id, kind, urgency, flow, afterPads, question, logOnEnter, entryPhrases, metronome, metronomeToggleable
        case frameUplink, overlay, guide, allowsPpg, allowedSay, repeating, timeout, transitions, citation
        case cues, locateMaterials
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        urgency = try c.decode(Int.self, forKey: .urgency)
        flow = try c.decodeIfPresent(String.self, forKey: .flow)
        afterPads = try c.decodeIfPresent(String.self, forKey: .afterPads)
        question = try c.decodeIfPresent(Question.self, forKey: .question)
        logOnEnter = try c.decodeIfPresent(LogEntry.Kind.self, forKey: .logOnEnter)
        entryPhrases = try c.decode([String].self, forKey: .entryPhrases)
        metronome = try c.decode(MetronomeRule.self, forKey: .metronome)
        metronomeToggleable = try c.decodeIfPresent(Bool.self, forKey: .metronomeToggleable) ?? false
        frameUplink = try c.decode(Bool.self, forKey: .frameUplink)
        overlay = try c.decodeIfPresent(OverlayTarget.self, forKey: .overlay)
        guide = try c.decodeIfPresent(Guide.self, forKey: .guide)
        allowsPpg = try c.decodeIfPresent(Bool.self, forKey: .allowsPpg) ?? false
        allowedSay = try c.decode([String].self, forKey: .allowedSay)
        repeating = try c.decodeIfPresent([RepeatingPrompt].self, forKey: .repeating) ?? []
        timeout = try c.decodeIfPresent(Timeout.self, forKey: .timeout)
        transitions = try c.decode([Transition].self, forKey: .transitions)
        citation = try c.decode(String.self, forKey: .citation)
        // Core's frozen file has neither, so it decodes exactly as before.
        cues = try c.decodeIfPresent([Cue].self, forKey: .cues) ?? []
        locateMaterials = try c.decodeIfPresent(Bool.self, forKey: .locateMaterials) ?? false
    }

    public func transition(on key: String) -> Transition? {
        transitions.first { $0.on == key }
    }

    /// Pads are on and the AED is analyzing, so nothing on the phone may talk over it.
    public var aedHasAuthority: Bool { logOnEnter == .padsOn }
}
