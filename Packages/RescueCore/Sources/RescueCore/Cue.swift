import Foundation

/// What a step points at on the camera while it runs: a body part, a material in the room, or both.
/// It hangs off a line the step already says, and its callout repeats that line's own words, so the
/// screen never adds advice of its own. Only a module's awake steps may carry one, and the model
/// never sees or names one.
public struct Cue: Sendable, Equatable, Codable {
    /// Where on the patient. Both hang off the pin a person tapped, which stays the authority.
    public enum Body: String, Sendable, Codable, CaseIterable {
        /// The arm or leg nearest the pin.
        case injuredLimb = "injured_limb"
        /// The pin itself, where hands press.
        case injurySite = "injury_site"
    }

    /// Where the material goes, against the body part.
    public enum Placement: String, Sendable, Codable, CaseIterable {
        case under, on, behind
    }

    public var phrase: String
    public var material: Material?
    public var body: Body?
    public var placement: Placement?
    /// The chip's whole text, drawn as written: nothing joined on and no placeholders.
    public var callout: String?
    /// What the file named that no case matches. Kept so the loader can refuse the module by name
    /// rather than as "does not decode". A cue that loaded has none.
    var unknownValues: [String] = []

    public init(phrase: String, material: Material? = nil, body: Body? = nil, placement: Placement? = nil, callout: String? = nil) {
        self.phrase = phrase
        self.material = material
        self.body = body
        self.placement = placement
        self.callout = callout
    }

    private enum CodingKeys: String, CodingKey {
        case phrase, material, body, placement, callout
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phrase = try c.decode(String.self, forKey: .phrase)
        callout = try c.decodeIfPresent(String.self, forKey: .callout)
        var unknown: [String] = []
        func value<T: RawRepresentable<String>>(_ key: CodingKeys) throws -> T? {
            guard let raw = try c.decodeIfPresent(String.self, forKey: key) else { return nil }
            guard let value = T(rawValue: raw) else {
                unknown.append("\(key.stringValue) \(raw)")
                return nil
            }
            return value
        }
        material = try value(.material)
        body = try value(.body)
        placement = try value(.placement)
        unknownValues = unknown
    }
}

extension StateDefinition {
    /// Lines a step lists only so a cue can point from them. Each answers a report, or nothing, and
    /// never a say: the model doesn't get to make the phone name a towel.
    var cueOnlyLines: Set<String> { Set(cues.map(\.phrase)).intersection(allowedSay) }

    /// The materials these states' cues name, once each, in `Material` order.
    static func materials(cuedIn states: [StateDefinition]) -> [Material] {
        let named = Set(states.flatMap(\.cues).compactMap(\.material))
        return Material.allCases.filter(named.contains)
    }

    /// This state and the others in its flow. A state outside any flow stands alone.
    func flowmates(in states: [StateDefinition]) -> [StateDefinition] {
        guard let flow else { return [self] }
        return states.filter { $0.flow == flow }
    }
}

extension ProtocolBundle {
    /// Everything the cues of this state's flow name. A locate takes seconds, so the app looks for
    /// all of them from the flow's first step, and the answer is in by the step that points at one.
    public func materials(inFlowOf state: StateDefinition) -> [Material] {
        StateDefinition.materials(cuedIn: state.flowmates(in: definition.states))
    }
}
