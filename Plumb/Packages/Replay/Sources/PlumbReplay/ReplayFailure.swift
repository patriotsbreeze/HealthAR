import Foundation

/// Why a replay, a fit or a score was refused.
public enum ReplayFailure: Error, Equatable, CustomStringConvertible {
    /// The along-ray height is the LiDAR range itself, so it has nothing to measure without it.
    case alongRayNeedsRange
    /// The gain was fitted on this very recording, so scoring it would only grade the fit.
    case scoredOnCalibrationTrace
    /// No locked compression to fit a gain from.
    case nothingToFit

    /// The reason in plain words.
    public var description: String {
        switch self {
        case .alongRayNeedsRange:
            "The along-ray height is the LiDAR range itself, so it cannot run without it. Use the image-plane method."
        case .scoredOnCalibrationTrace:
            "This recording set the gain, so it cannot be scored with it. Score a different recording."
        case .nothingToFit:
            "No locked pushes to fit a gain from."
        }
    }
}
