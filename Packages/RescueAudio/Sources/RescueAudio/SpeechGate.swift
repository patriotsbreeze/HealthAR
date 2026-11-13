import Synchronization

/// Decides whether model audio may reach the ring. Audio dropped here is never heard.
///
/// Closed by default, so a missing policy leaves the model silent. Also stops any turn that runs
/// past 20 s of audio. It counts samples, not wall time, because the model can stream faster than
/// real time.
public final class SpeechGate: Sendable {
    public static let runawayLimitSeconds = 20

    public enum Admission: Sendable, Equatable {
        /// Push this many samples. Fewer than offered when a chunk crosses the runaway limit.
        case pass(sampleCount: Int)
        case closed
        /// `justTripped` is true once per turn, so the caller can report it once.
        case runaway(justTripped: Bool)
    }

    private let turnLimit: Int
    private let open = Atomic<Bool>(false)
    private let turnSamples = Atomic<Int>(0)
    private let tripped = Atomic<Bool>(false)

    public init(sampleRate: Int) {
        turnLimit = sampleRate * Self.runawayLimitSeconds
    }

    public var isOpen: Bool { open.load(ordering: .acquiring) }

    public func setOpen(_ value: Bool) {
        open.store(value, ordering: .releasing)
    }

    /// The model finished or was interrupted. The next audio starts a fresh 20 s budget.
    public func endTurn() {
        turnSamples.store(0, ordering: .relaxed)
        tripped.store(false, ordering: .relaxed)
    }

    public func admit(sampleCount: Int) -> Admission {
        guard isOpen else { return .closed }
        guard sampleCount > 0 else { return .pass(sampleCount: 0) }
        let total = turnSamples.add(sampleCount, ordering: .relaxed).newValue
        let allowed = min(sampleCount, turnLimit - (total - sampleCount))
        if allowed > 0 { return .pass(sampleCount: allowed) }
        return .runaway(justTripped: !tripped.exchange(true, ordering: .relaxed))
    }
}
