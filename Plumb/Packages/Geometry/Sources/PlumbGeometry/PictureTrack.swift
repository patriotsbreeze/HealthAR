import Foundation
import simd

/// Follows the picture of the hands for the image-plane method.
///
/// The shift estimator measures how far the picture slid inside the luma grid. This adds how far
/// the grid itself was moved since the key frame, so a grid that is laid somewhere else between
/// frames does not read as the hands moving.
struct PictureTrack: Sendable {
    private var estimator: ShiftEstimator
    private var isKeyed = false
    /// Where the grid's centre sat in the image when the key frame was taken, if it was reported.
    private var keyCentre: SIMD2<Double>?

    init(config: ShiftEstimator.Config) {
        estimator = ShiftEstimator(config: config)
    }

    /// How far the hands' picture has travelled along `upDirection` in the image since the key
    /// frame, in pixels, and how well it matched (0...1). Nil when the patch is malformed.
    mutating func travel(of patch: LumaPatch, gridCentre: SIMD2<Double>?,
                         upDirection: SIMD2<Double>) -> (upPx: Double, correlation: Double)? {
        guard let slide = estimator.estimate(patch) else { return nil }
        guard isKeyed else {
            isKeyed = true
            keyCentre = gridCentre
            return slide
        }
        // Without both centres there is nothing to compare, and the grid is taken to have stayed put.
        guard let gridCentre, let keyCentre else { return slide }
        return (slide.upPx + simd_dot(gridCentre - keyCentre, upDirection), slide.correlation)
    }

    /// Makes `patch` the new key frame.
    mutating func restart(from patch: LumaPatch, gridCentre: SIMD2<Double>?) {
        estimator.rekey()
        isKeyed = false
        _ = travel(of: patch, gridCentre: gridCentre, upDirection: .zero)
    }
}
