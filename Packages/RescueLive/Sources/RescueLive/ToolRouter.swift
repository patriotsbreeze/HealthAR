import Foundation
import RescueCore

/// The voice model's description of the camera view, for the screen only. It never becomes a
/// proposal, so the engine never sees it, and the app screens its words before showing them.
public struct SceneReport: Sendable, Equatable {
    public var sees: String
    public var headline: String
    public var prediction: String
    public var confidence: SituationAssessment.Confidence
    /// One line from the voice AI on what changed and why it matters. The live log's reasoning.
    public var note: String
    /// A few words for a possible emergency in view, or empty when there isn't one.
    public var emergency: String
    public var stateVersion: Int

    public init(sees: String, headline: String, prediction: String, confidence: SituationAssessment.Confidence, note: String = "", emergency: String = "", stateVersion: Int) {
        self.note = note
        self.emergency = emergency
        self.sees = sees
        self.headline = headline
        self.prediction = prediction
        self.confidence = confidence
        self.stateVersion = stateVersion
    }
}

/// The voice model's read that the rescuer's own words chose a button on screen. Like a scene report
/// it never becomes a proposal: the app decides whether to press it, as if the rescuer had tapped.
public struct ButtonPress: Sendable, Equatable {
    public var action: HumanAction
    public var stateVersion: Int

    public init(action: HumanAction, stateVersion: Int) {
        self.action = action
        self.stateVersion = stateVersion
    }
}

/// Decodes a model function call into a `ModelProposal`, or refuses it. The arguments are
/// untrusted, so nothing is coerced: names and enum values must match exactly, and every argument
/// must be one the contract declares. The engine then decides whether a proposal does anything.
public struct ToolRouter: Sendable {
    public struct Routed: Sendable, Equatable {
        public var proposal: ModelProposal?
        /// Nil only when the call has no usable id, since there is then nothing to answer.
        public var response: ToolResponse?
        /// A `report_scene` call. Never alongside a proposal.
        public var scene: SceneReport? = nil
        /// A `press_button` call. Never alongside a proposal.
        public var press: ButtonPress? = nil
    }

    private enum Tool: String {
        case reportFinding = "report_finding"
        case reportResources = "report_resources"
        case say
        case locateObject = "locate_object"
        case logEvent = "log_event"

        var argumentNames: Set<String> {
            switch self {
            case .reportFinding: ["kind", "source", "confidence", "state_version"]
            case .reportResources: ["items", "state_version"]
            case .say: ["phrase_id", "state_version"]
            case .locateObject: ["label", "state_version"]
            case .logEvent: ["kind", "state_version"]
            }
        }
    }

    private static let maxIDBytes = 256
    /// The API reference's limit on a function name.
    private static let maxNameLength = 128
    private static let maxPhraseIDBytes = 64
    private static let maxResourceItems = 16
    /// Longer than any field the contract asks for. A field past this is off contract, not clipped.
    private static let maxSceneField = 200
    private static let sceneArguments: Set<String> = ["sees", "headline", "prediction", "confidence", "note", "emergency", "state_version"]

    private let clock: @Sendable () -> TimeInterval
    /// What this session's contract declares. A real finding outside it is still off contract.
    private let allowedFindings: Set<Finding>

    public init(clock: @escaping @Sendable () -> TimeInterval, allowedFindings: Set<Finding> = Finding.arrestCases) {
        self.clock = clock
        self.allowedFindings = allowedFindings
    }

    public func route(_ call: RealtimeFunctionCall) -> Routed {
        guard let id = call.id, !id.isEmpty, id.utf8.count <= Self.maxIDBytes else {
            return Routed(proposal: nil, response: nil)
        }
        let name = call.name.flatMap { $0.isEmpty ? nil : String($0.prefix(Self.maxNameLength)) } ?? "unknown"

        if call.name == "report_scene" {
            guard let scene = Self.scene(call.args) else {
                return Routed(proposal: nil, response: ToolResponse(id: id, name: name, status: .rejected, reason: .invalidArguments))
            }
            return Routed(proposal: nil, response: ToolResponse(id: id, name: name, status: .received, reason: nil), scene: scene)
        }

        if call.name == "press_button" {
            guard let press = Self.press(call.args) else {
                return Routed(proposal: nil, response: ToolResponse(id: id, name: name, status: .rejected, reason: .invalidArguments))
            }
            return Routed(proposal: nil, response: ToolResponse(id: id, name: name, status: .received, reason: nil), press: press)
        }

        switch Self.decode(name: call.name, args: call.args, allowedFindings: allowedFindings) {
        case let .success(decoded):
            let proposal = ModelProposal(action: decoded.action, stateVersion: decoded.stateVersion, issuedAt: clock())
            return Routed(proposal: proposal, response: ToolResponse(id: id, name: name, status: .received, reason: nil))
        case let .failure(rejection):
            return Routed(proposal: nil, response: ToolResponse(id: id, name: name, status: .rejected, reason: rejection.reason))
        }
    }

    private struct Decoded {
        let action: ModelProposal.Action
        let stateVersion: Int
    }

    private struct Rejection: Error {
        let reason: ToolResponse.RejectReason
    }

    private static func decode(name: String?, args: JSONValue?, allowedFindings: Set<Finding>) -> Result<Decoded, Rejection> {
        guard let tool = name.flatMap(Tool.init(rawValue:)) else {
            return .failure(Rejection(reason: .unknownTool))
        }
        guard let args else { return .failure(Rejection(reason: .missingStateVersion)) }
        guard case let .object(fields) = args else {
            return .failure(Rejection(reason: .invalidArguments))
        }
        guard let quoted = fields["state_version"], quoted != .null else {
            return .failure(Rejection(reason: .missingStateVersion))
        }
        guard let version = stateVersion(quoted) else {
            return .failure(Rejection(reason: .invalidArguments))
        }
        // Missing or undeclared arguments mean the model left the contract.
        guard Set(fields.keys) == tool.argumentNames else {
            return .failure(Rejection(reason: .invalidArguments))
        }
        guard let action = action(for: tool, fields: fields, allowedFindings: allowedFindings) else {
            return .failure(Rejection(reason: .unknownValue))
        }
        return .success(Decoded(action: action, stateVersion: version))
    }

    private static func action(for tool: Tool, fields: [String: JSONValue], allowedFindings: Set<Finding>) -> ModelProposal.Action? {
        switch tool {
        case .reportFinding:
            guard let finding: Finding = enumValue(fields["kind"]),
                  allowedFindings.contains(finding),
                  let source: ObservationSource = enumValue(fields["source"]),
                  let confidence: Confidence = enumValue(fields["confidence"])
            else { return nil }
            return .reportFinding(finding, source: source, confidence: confidence)

        case .reportResources:
            guard case let .array(items)? = fields["items"],
                  !items.isEmpty, items.count <= maxResourceItems
            else { return nil }
            let resources: [Resource] = items.compactMap(enumValue)
            return resources.count == items.count ? .reportResources(resources) : nil

        case .say:
            guard case let .string(phrase)? = fields["phrase_id"], isPlausiblePhraseID(phrase) else { return nil }
            return .say(phraseID: phrase)

        case .locateObject:
            guard let object: LocatableObject = enumValue(fields["label"]) else { return nil }
            return .locateObject(object)

        case .logEvent:
            guard let note: ModelNote = enumValue(fields["kind"]) else { return nil }
            return .logEvent(note)
        }
    }

    /// Every argument present, nothing extra, short strings, and a known confidence.
    private static func scene(_ args: JSONValue?) -> SceneReport? {
        guard case let .object(fields)? = args, Set(fields.keys) == sceneArguments,
              let version = fields["state_version"].flatMap(stateVersion),
              let confidence: SituationAssessment.Confidence = enumValue(fields["confidence"])
        else { return nil }
        func text(_ key: String) -> String? {
            guard case let .string(value)? = fields[key] else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.count > maxSceneField ? nil : trimmed
        }
        guard let sees = text("sees"), let headline = text("headline"), let prediction = text("prediction"), let note = text("note"),
              case let .string(emergency)? = fields["emergency"], emergency.count <= maxSceneField
        else { return nil }
        // Empty is the usual answer, so it's allowed here, unlike the other fields.
        return SceneReport(sees: sees, headline: headline, prediction: prediction, confidence: confidence, note: note,
                           emergency: emergency.trimmingCharacters(in: .whitespacesAndNewlines), stateVersion: version)
    }

    /// Exactly a known button and a version, nothing else.
    private static func press(_ args: JSONValue?) -> ButtonPress? {
        guard case let .object(fields)? = args, Set(fields.keys) == ["button", "state_version"],
              let action: HumanAction = enumValue(fields["button"]),
              let version = fields["state_version"].flatMap(stateVersion)
        else { return nil }
        return ButtonPress(action: action, stateVersion: version)
    }

    private static func enumValue<T: RawRepresentable>(_ field: JSONValue?) -> T? where T.RawValue == String {
        guard case let .string(raw)? = field else { return nil }
        return T(rawValue: raw)
    }

    /// JSON has one number type, so 3.0 is accepted as 3. A string, fraction, or negative is not.
    private static func stateVersion(_ field: JSONValue) -> Int? {
        guard case let .number(value) = field, let version = Int(exactly: value), version >= 0 else { return nil }
        return version
    }

    /// The engine checks the id against the allowed list. This only keeps odd text out of the log.
    private static func isPlausiblePhraseID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= maxPhraseIDBytes && id.utf8.allSatisfy { byte in
            (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte) || byte == 0x5F || byte == 0x2E || byte == 0x2D
        }
    }
}
