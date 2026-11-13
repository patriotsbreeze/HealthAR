import Foundation
import PlumbContracts

/// What the app last said about the guides, and the fixed rules for what that shows.
struct GuideState: Sendable, Equatable {
    /// How the target line is drawn.
    enum LineStyle: Sendable, Equatable {
        /// Depth is trusted: the line can be judged against.
        case solid
        /// A signal is there but depth is not trusted: the line is only a hint.
        case dashed
    }

    /// How far the measurement can be trusted right now.
    var lock: LockState
    /// True while compressions are going on.
    var compressing: Bool
    /// False hides every guide.
    var visible: Bool

    /// Before the app says anything: nothing is trusted, nothing is going on, and the ring may show.
    static let initial = GuideState(lock: .lost, compressing: false, visible: true)

    /// The ring shows whenever the guides are visible. Once compressions start the hands cover it,
    /// and occlusion hides it under them.
    var showsRing: Bool { visible }

    /// The line shows only while compressing, solid when locked and dashed when estimating. With
    /// only the rhythm trusted, or nothing, there is no depth to aim for and no line.
    var lineStyle: LineStyle? {
        guard visible, compressing else { return nil }
        switch lock {
        case .locked: return .solid
        case .estimating: return .dashed
        case .rateOnly, .lost: return nil
        }
    }
}
