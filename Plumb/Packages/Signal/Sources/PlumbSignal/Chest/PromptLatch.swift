import Foundation

/// The "start pushing" prompt. It goes on by itself and has no way to go off.
///
/// Movement seen after the prompt never means the person is all right, so nothing the sensor sees may
/// take it back. The only way to clear it is to replace the whole check, which `reset()` does when a person asks.
struct PromptLatch: Equatable, Sendable {
    /// When the prompt became due. Nil until then.
    private(set) var firedAt: TimeInterval?

    var isOn: Bool { firedAt != nil }

    /// Turns the prompt on. A later call changes nothing, so the first moment is the one kept.
    mutating func fire(at t: TimeInterval) {
        if firedAt == nil { firedAt = t }
    }
}
