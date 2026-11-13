import CoreGraphics
import Foundation
import Vision

/// The joints of one detected person that seeding uses, in image pixels (u right, v down, origin
/// at the top-left of the captured image). A joint Vision did not find, or found with too little
/// confidence, is nil.
struct BodyJoints: Sendable, Equatable {
    var leftWrist: SIMD2<Double>?
    var rightWrist: SIMD2<Double>?
    var leftElbow: SIMD2<Double>?
    var rightElbow: SIMD2<Double>?
    var leftShoulder: SIMD2<Double>?
    var rightShoulder: SIMD2<Double>?
}

extension BodyJoints {
    /// Reads the joints out of one observation of an image `imageSize` pixels big, keeping those
    /// Vision gave at least `minConfidence`.
    init(_ observation: HumanBodyPoseObservation, imageSize: CGSize, minConfidence: Double) {
        func point(_ name: HumanBodyPoseObservation.JointName) -> SIMD2<Double>? {
            guard let joint = observation.joint(for: name), Double(joint.confidence) >= minConfidence else {
                return nil
            }
            return Self.pixel(of: joint.location, imageSize: imageSize)
        }
        self.init(leftWrist: point(.leftWrist), rightWrist: point(.rightWrist),
                  leftElbow: point(.leftElbow), rightElbow: point(.rightElbow),
                  leftShoulder: point(.leftShoulder), rightShoulder: point(.rightShoulder))
    }

    /// Image pixel of a Vision point. Vision's normalised points have their origin at the lower-left
    /// (y grows upward), so v is flipped on the way to the top-left pixel convention used here.
    static func pixel(of point: NormalizedPoint, imageSize: CGSize) -> SIMD2<Double> {
        let pixel = point.toImageCoordinates(imageSize, origin: .upperLeft)
        return SIMD2(Double(pixel.x), Double(pixel.y))
    }
}
