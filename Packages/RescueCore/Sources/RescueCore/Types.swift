import Foundation

/// Something a person did on the device. Only these can lower urgency or leave CPR.
public enum HumanAction: String, Sendable, Codable, CaseIterable {
    case yes, no, unsure, back, called, done, scan
    case startCpr = "start_cpr"
    case notAdult = "not_adult"
    case aedHere = "aed_here"
    case padsOn = "pads_on"
    case aedSaysCpr = "aed_says_cpr"
    case aedAnalyzing = "aed_analyzing"
    case emsArrived = "ems_arrived"
    case patientMoving = "patient_moving"
    case patientAwake = "patient_awake"
    case patientUnresponsive = "patient_unresponsive"
    case patientNotBreathing = "patient_not_breathing"
    case resumeCpr = "resume_cpr"
    case triageChest = "triage_chest"
    case triageLimb = "triage_limb"
    case triageOther = "triage_other"
    case triageChoking = "triage_choking"
    case triageOpen = "triage_open"
    case notThis = "not_this"
    case cantCough = "cant_cough"
    case objectOut = "object_out"
    // These never change state.
    case breathMarked = "breath_marked"
    case shockDelivered = "shock_delivered"
    case metronomeOn = "metronome_on"
    case metronomeOff = "metronome_off"
    case dispatcherOn = "dispatcher_on"
    case dispatcherOff = "dispatcher_off"
    case secondPerson = "second_person"
}

/// What the model says it heard or saw. An observation, never a command.
public enum Finding: String, Sendable, Codable, CaseIterable {
    case unresponsive, responsive
    case abnormalBreathing = "abnormal_breathing"
    case notBreathing = "not_breathing"
    case breathingNormally = "breathing_normally"
    case patientMoving = "patient_moving"
    case emsArrived = "ems_arrived"
    case dispatcherSpeaking = "dispatcher_speaking"
    case aedPrompting = "aed_prompting"
    case chestPain = "chest_pain"
    case otherHeartSigns = "other_heart_signs"
    case limbInjury = "limb_injury"
    case limbDiscolored = "limb_discolored"
    case heavyBleeding = "heavy_bleeding"
    case neckBackInjury = "neck_back_injury"
    case choking
    case otherConcern = "other_concern"
    case aspirinUnsafe = "aspirin_unsafe"
    /// The rescuer says they finished what the step asked, such as five back blows.
    case stepDone = "step_done"
    /// The choking patient is coughing hard, talking, or breathing freely.
    case canCough = "can_cough"
    /// Someone says the object came out.
    case objectOut = "object_out"

    /// What `contracts/tools.v1.json` declares. Awake findings stay out of an arrest session.
    public static let arrestCases: Set<Finding> = [
        .unresponsive, .responsive, .abnormalBreathing, .notBreathing, .breathingNormally,
        .patientMoving, .emsArrived, .dispatcherSpeaking, .aedPrompting,
    ]

    /// What `contracts/tools.awake.v1.json` declares. "I'm fine" can't flood an awake session's Sentinel lane.
    public static let awakeCases: Set<Finding> = [
        .unresponsive, .notBreathing, .abnormalBreathing, .dispatcherSpeaking, .chestPain, .otherHeartSigns,
        .limbInjury, .limbDiscolored, .heavyBleeding, .neckBackInjury, .choking, .otherConcern, .aspirinUnsafe,
        .stepDone, .canCough, .objectOut,
    ]

    /// Acting on these would reduce urgency, so the model can never trigger them.
    public var wouldLowerUrgency: Bool {
        switch self {
        // A cough that works, or the object out, would take the rescuer off back blows. Only a person
        // may choose that, so the app rings the button and waits for a tap or "confirm".
        case .responsive, .breathingNormally, .patientMoving, .emsArrived, .canCough, .objectOut: true
        default: false
        }
    }
}

/// Which Live session a state needs. A prompt and a contract are set at connect, so each mode has its own.
public enum LiveMode: String, Sendable, Equatable, CaseIterable {
    case arrest, awake

    public var profile: ValidatorProfile {
        switch self {
        case .arrest: .arrest
        case .awake: .awake
        }
    }

    public var allowedFindings: Set<Finding> {
        switch self {
        case .arrest: Finding.arrestCases
        case .awake: Finding.awakeCases
        }
    }
}

public enum ObservationSource: String, Sendable, Codable, CaseIterable { case heard, seen }

public enum Confidence: String, Sendable, Codable, CaseIterable, Comparable {
    case low, medium, high

    public static func < (a: Confidence, b: Confidence) -> Bool { a.rank < b.rank }

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }
}

public enum Resource: String, Sendable, Codable, CaseIterable {
    case aed, gloves, towel, tourniquet
    case secondPerson = "second_person"
}

public enum LocatableObject: String, Sendable, Codable, CaseIterable { case aed }

public enum ModelNote: String, Sendable, Codable, CaseIterable {
    case witnessedCollapse = "witnessed_collapse"
    case vomiting
    case seizureActivity = "seizure_activity"
    case bystanderDistress = "bystander_distress"
    case other
}

public enum OverlayTarget: String, Sendable, Codable, CaseIterable {
    case chestCenter = "chest_center"
    case aedDevice = "aed_device"
    case padZones = "pad_zones"
    case injurySite = "injury_site"
    /// Between the shoulder blades of a standing patient, for back blows.
    case upperBack = "upper_back"
    /// Just above the navel of a standing patient, for abdominal thrusts.
    case upperAbdomen = "upper_abdomen"
}

/// A tool call from the model. All arguments are enums, and each call names the state version it saw.
public struct ModelProposal: Sendable, Equatable, Codable {
    public enum Action: Sendable, Equatable, Codable {
        case reportFinding(Finding, source: ObservationSource, confidence: Confidence)
        case reportResources([Resource])
        case say(phraseID: String)
        case locateObject(LocatableObject)
        case logEvent(ModelNote)
    }

    public var action: Action
    public var stateVersion: Int
    public var issuedAt: TimeInterval

    public init(action: Action, stateVersion: Int, issuedAt: TimeInterval) {
        self.action = action
        self.stateVersion = stateVersion
        self.issuedAt = issuedAt
    }

    public var summary: String {
        switch action {
        case let .reportFinding(finding, source, confidence):
            "report_finding(\(finding.rawValue), \(source.rawValue), \(confidence.rawValue))"
        case let .reportResources(items):
            "report_resources(\(items.map(\.rawValue).joined(separator: ",")))"
        case let .say(phraseID):
            "say(\(phraseID))"
        case let .locateObject(object):
            "locate_object(\(object.rawValue))"
        case let .logEvent(note):
            "log_event(\(note.rawValue))"
        }
    }
}

public enum AudioKeyword: String, Sendable, Codable, CaseIterable {
    case aedTalking = "aed_talking"
    case dispatcherTalking = "dispatcher_talking"
}

public enum RescueEvent: Sendable, Equatable {
    case human(HumanAction)
    case model(ModelProposal)
    /// Advances time-based rules. The engine has no clock of its own.
    case tick
    case callChanged(active: Bool)
    case keyword(AudioKeyword)
    case sentinelFlag(SentinelFlag)
    case phrasePlayed(String)
    /// The model's voice started or finished a turn. The engine has no ears of its own.
    case modelTurn(active: Bool)
}

public enum AudioMode: String, Sendable, Codable {
    /// `playAndRecord` with voice processing. Mic and model audio available.
    case full
    /// `playback` only, because a call is active. Metronome and local phrases.
    case playbackOnly = "playback_only"
}

public struct RuntimePolicy: Sendable, Equatable {
    public var modelSpeechOpen: Bool
    public var micUplink: Bool
    public var frameUplink: Bool
    public var audioMode: AudioMode
    /// With the uplink open, frames go only in a burst, which speech starts, and not on the idle timer.
    public var frameBurstsOnly = false
    /// Model audio that arrives during a local phrase plays after it, and isn't dropped. Someone awake
    /// is waiting on that answer, and it arrives far faster than it plays, so it could go whole.
    public var modelAudioWaitsForPhrases = false
    /// An AED found here is remembered for a later arrest. Only an awake scan's is, so an arrest-only
    /// rescue looks as it always has.
    public var aedFindsCarry = false
    /// Draws that remembered AED, on a state that has no overlay of its own.
    public var showsCarriedAED = false
    /// Single frozen frames may go to the one-shot locator, to find the flow's materials. Never to the
    /// Live session, which `frameUplink` alone opens.
    public var frameLocate = false
}

public enum RescueEffect: Sendable, Equatable {
    case playPhrase(String)
    case metronome(on: Bool)
    case overlay(OverlayTarget?)
    /// The step's cues, sent on every entry next to the overlay. Empty clears the last step's marks.
    case cues([Cue])
    case flushModelAudio
    /// Forgets phrases that haven't started, except these. The one playing finishes.
    case dropQueuedPhrases(keeping: [String])
    /// Silences the phrase lane at once and forgets everything in it.
    case cutPhrases
    case pauseAudio(seconds: TimeInterval)
    case resumeAudio
    case locate(LocatableObject)
    case policyChanged(RuntimePolicy)
    case sendStateBrief(StateBrief)
}

/// Where aspirin stands. `recentlyPlayed` holds 3 phrases, so the line that settled it soon falls out of that.
public enum AspirinStatus: String, Sendable, Equatable {
    case notAsked = "not_asked"
    case advised
    case ruledOut = "ruled_out"
}

/// What the model is told about the current state. Lists phrases actually played, since
/// the model otherwise assumes audio the speech gate dropped was heard.
public struct StateBrief: Sendable, Equatable {
    public var version: Int
    public var stateID: String
    public var allowedSay: [String]
    public var modelSpeechOpen: Bool
    public var recentlyPlayed: [String]
    public var resources: [String]
    public var elapsedSeconds: Int
    /// Only an awake state sets these. Unset, the text is what an arrest session has always been sent.
    public var mode: LiveMode?
    public var flow: String?
    public var stepText: String?
    public var aspirin = AspirinStatus.notAsked

    public var text: String {
        let base = """
        STATE BRIEF version=\(version) state=\(stateID) elapsed_seconds=\(elapsedSeconds)
        you_may_speak=\(modelSpeechOpen)
        allowed_say=[\(allowedSay.joined(separator: ","))]
        recently_played=[\(recentlyPlayed.joined(separator: ","))]
        resources=[\(resources.joined(separator: ","))]
        """
        guard let mode, mode == .awake else { return base }
        return base + """

        mode=\(mode.rawValue)
        flow=\(flow ?? "none")
        step=\(stepText ?? "none")
        aspirin=\(aspirin.rawValue)
        """
    }
}
