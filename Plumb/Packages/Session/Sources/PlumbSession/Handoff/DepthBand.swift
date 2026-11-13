import Foundation
import PlumbContracts

/// The depth range as people are shown it: two different ends, in centimetres, on a coarse step.
/// A range, never one number, because one number would claim more precision than the camera has.
struct DepthBand: Equatable {
    var lowCM: Double
    var highCM: Double

    /// Nil when the stats hold no trusted depth.
    init?(_ stats: HandoffStats, stepCM: Double) {
        guard let lowMM = stats.depthLowMM ?? stats.depthMM,
              let highMM = stats.depthHighMM ?? stats.depthMM,
              lowMM.isFinite, highMM.isFinite, stepCM.isFinite, stepCM > 0 else { return nil }
        let low = min(lowMM, highMM) / Units.mmPerCM
        let high = max(lowMM, highMM) / Units.mmPerCM

        var lowStep = (low / stepCM).rounded()
        var highStep = (high / stepCM).rounded()
        if highStep <= lowStep {
            // Both ends landed on the same mark. Open the range outwards to the marks either
            // side of the measured values, and to one full step when they sit on a mark exactly.
            lowStep = (low / stepCM).rounded(.down)
            highStep = max((high / stepCM).rounded(.up), lowStep + 1)
        }
        lowCM = lowStep * stepCM
        highCM = highStep * stepCM
    }
}
