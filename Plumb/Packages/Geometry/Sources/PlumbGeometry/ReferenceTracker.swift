import Foundation

/// Watches the measured height of something that does not move.
///
/// Whatever that height appears to do is error in the camera's idea of where it is. The tracker
/// turns it into a correction to take off the hands' height, and into a noise figure.
struct ReferenceTracker: Sendable {
    private var window: TimedWindow
    private let minReadings: Int
    private let jumpMM: Double
    private let maxDriftMMPerS: Double
    private let fastShare: Double

    /// The reference's level when it was first believed; drift is measured from here.
    private var anchorMM: Double?
    /// The reference's level at the last frame it was believed.
    private var levelMM: Double?
    /// The slow part of the correction: how far the level has crept from the anchor.
    private var driftMM = 0.0
    private var lastFrameT: TimeInterval?

    /// Millimetres to subtract from a height measured in the same frame.
    private(set) var correctionMM = 0.0

    init(config: HeightEstimator.Config) {
        window = TimedWindow(spanS: config.referenceWindowS)
        minReadings = config.referenceMinReadings
        jumpMM = config.referenceJumpMM
        maxDriftMMPerS = config.referenceMaxDriftMMPerS
        fastShare = config.referenceFastShare
    }

    /// How much the reference appears to move: the standard deviation of its recent heights.
    /// Nil until enough readings are in the window.
    var noiseMM: Double? {
        window.count >= minReadings ? window.standardDeviation : nil
    }

    /// Takes in the reference's measured height for the frame at time `t`.
    mutating func observe(heightMM: Double, at t: TimeInterval) {
        let elapsed = secondsSinceLastFrame(at: t)
        window.add(heightMM, at: t)
        guard window.count >= minReadings, let level = window.median else {
            correctionMM = driftMM
            return
        }
        let anchor: Double
        if let held = anchorMM, let previous = levelMM {
            // The camera's drift is slow. A level that leaps is the patch now showing something
            // else, so move the anchor with it and leave the correction where it was.
            anchor = abs(level - previous) > jumpMM ? held + (level - previous) : held
        } else {
            anchor = level
        }
        anchorMM = anchor
        levelMM = level
        // Follow the level no faster than drift can go, so the correction never steps the heights.
        let behind = level - anchor - driftMM
        let reach = maxDriftMMPerS * elapsed
        driftMM += min(max(behind, -reach), reach)
        // A single reading far from the level is something passing in front, not the camera.
        let deviation = heightMM - level
        correctionMM = driftMM + (abs(deviation) <= jumpMM ? fastShare * deviation : 0)
    }

    /// Marks a frame at time `t` that had no reference reading. The last known drift stays in
    /// force, so the heights do not step when the reference comes and goes.
    mutating func advance(to t: TimeInterval) {
        _ = secondsSinceLastFrame(at: t)
        window.advance(to: t)
        correctionMM = driftMM
    }

    /// Time since the previous frame; zero for the first frame or a clock that stepped back.
    private mutating func secondsSinceLastFrame(at t: TimeInterval) -> TimeInterval {
        defer { lastFrameT = t }
        return max(0, t - (lastFrameT ?? t))
    }
}
