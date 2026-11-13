/// Things in the room a step can point at. Module cues name these, and the app locates them on a
/// frozen frame. The model never names one: its tools keep `Resource` and `LocatableObject`, so the
/// contracts don't change.
///
/// Clothing and blankets are left out on purpose. A locator asked for clothes boxes what people are
/// wearing, and a confident wrong callout gets followed.
public enum Material: String, Sendable, Codable, CaseIterable, Hashable {
    case towel, pillow, gloves, aed

    /// What the locator is asked to find. Plain words, since this goes into a prompt.
    public var locatorLabel: String {
        switch self {
        case .towel: "towel or cloth"
        case .pillow: "pillow or cushion"
        case .gloves: "disposable gloves"
        case .aed: "AED (automated external defibrillator)"
        }
    }

    /// Words a cue's callout may use to name this material. The validator checks one is present.
    public var calloutNouns: Set<String> {
        switch self {
        case .towel: ["towel", "cloth"]
        case .pillow: ["pillow", "cushion"]
        case .gloves: ["gloves"]
        case .aed: ["aed"]
        }
    }

    /// An AED stays where it was seen. A towel or pillow gets picked up and moved.
    public var isFixed: Bool { self == .aed }
}
