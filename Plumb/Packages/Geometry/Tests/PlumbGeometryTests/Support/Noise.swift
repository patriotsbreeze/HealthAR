import Foundation
import PlumbContracts

/// Seeded random numbers for the renderer. Its normal draws cost one uniform draw each, where
/// `SplitMix64.nextGaussian` costs twelve, and a scene needs a few thousand a frame.
struct Noise {
    private var generator: SplitMix64
    private var spare: Double?

    init(seed: UInt64) {
        generator = SplitMix64(seed: seed)
    }

    /// Uniform in 0..<1.
    mutating func unit() -> Double {
        generator.nextUnit()
    }

    /// Normal, mean 0, standard deviation 1 (Box-Muller, which makes them two at a time).
    mutating func gaussian() -> Double {
        if let spare {
            self.spare = nil
            return spare
        }
        let radius = (-2 * log(1 - generator.nextUnit())).squareRoot()
        let angle = 2 * Double.pi * generator.nextUnit()
        spare = radius * sin(angle)
        return radius * cos(angle)
    }
}
