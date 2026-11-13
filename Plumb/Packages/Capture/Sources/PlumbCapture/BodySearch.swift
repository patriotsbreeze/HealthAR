import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// What one body pose search needs, copied out of a frame so the search can run while newer
/// frames keep arriving. `Sendable` unchecked because `image` is this package's own copy (see
/// `ImageCopier`), written before the search is handed it and only read after.
struct BodySearchInput: @unchecked Sendable {
    /// Copy of the captured image, in the sensor's native landscape orientation.
    let image: CVPixelBuffer
    /// Copy of the same frame's depth map.
    let depth: DepthMap
    /// The same frame's camera.
    let camera: FrameCamera
    /// The seeding generation the search was started in; a result from an older one is dropped.
    let generation: Int
}

/// Runs Vision's body pose request on a copied frame and applies the seeding rules.
enum BodySearch {
    /// The world point the hands press on, or nil when no one qualifies or Vision fails.
    static func run(_ input: BodySearchInput, config: CaptureConfig) async -> SIMD3<Double>? {
        let request = DetectHumanBodyPoseRequest()
        // Assumption: the phone is propped in landscape with its top to the left (the sensor's
        // native orientation, interface `.landscapeRight`), so people stand upright in the image
        // as delivered and no rotation is applied. Turned the other way they appear upside down.
        // A failed request just means no seed this time; the next search is a fifth of a second away.
        guard let observations = try? await request.perform(on: input.image, orientation: .up) else { return nil }
        let size = CGSize(width: input.camera.intrinsics.width, height: input.camera.intrinsics.height)
        let bodies = observations.map { BodyJoints($0, imageSize: size, minConfidence: config.minJointConfidence) }
        return HandsFinder.find(bodies, depth: input.depth, camera: input.camera, config: config)
    }
}
