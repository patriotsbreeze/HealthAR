import Foundation

/// What the chest check has to say at one moment. Cheap to copy; made a few times a second.
///
/// It reports what the sensor saw on a training mat and nothing more. "Movement seen" is a reading
/// of a few millimetres of height, never a statement that the person is all right.
public struct ChestReading: Sendable, Equatable {
    /// What the chest has been doing, as far as the sensor can tell.
    public enum State: Sendable, Equatable {
        /// Nothing usable to watch: no chest tapped yet, quality too poor, or no samples lately.
        case unmeasured
        /// Watching, but not yet for long enough to say either way.
        case settling
        /// The chest rose or fell by at least the threshold within the last window.
        case movementSeen
        /// The chest has stayed inside the threshold for at least the required time. Counts up, in seconds.
        case noMovementSeen(forSeconds: Double)
    }

    /// Time of the latest sample or tick, in session seconds.
    public var t: TimeInterval
    public var state: State
    /// True once "Start pushing" has been prompted. It stays true whatever the chest does next,
    /// and only `ChestMovementAnalyzer.reset()`, which a person asks for, turns it off.
    public var startPushing: Bool
    /// When the prompt became due: the moment the chest had been still for the required time. Nil before.
    public var promptedAt: TimeInterval?
    /// The rise or fall, in millimetres, that counts as movement right now.
    public var thresholdMM: Double
    /// Highest minus lowest smoothed height over the last window, in millimetres. Nil while unmeasured.
    public var swingMM: Double?
    /// The last stretch of chest height, ready to draw.
    public var trace: ChestTrace
}
