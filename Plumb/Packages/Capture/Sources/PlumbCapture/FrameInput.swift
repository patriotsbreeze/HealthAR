import ARKit
import CoreVideo
import Foundation

/// What the pipeline reads from one ARFrame. Lives only for the length of one `process` call:
/// it holds the frame's image buffer, which must go back to ARKit as soon as the call returns.
struct FrameInput {
    /// The frame's own capture time, on the system's uptime clock.
    var timestamp: TimeInterval
    var camera: FrameCamera
    var tracking: ARCamera.TrackingState
    /// A copy of the frame's raw depth map. Nil when the frame carried none.
    var depth: DepthMap?
    /// The captured image itself, borrowed from ARKit; never stored.
    var image: CVPixelBuffer
}

extension FrameInput {
    /// Reads what the pipeline needs out of `frame`, copying the depth map. Uses `sceneDepth`,
    /// never `smoothedSceneDepth`, whose smoothing would blunt every stroke.
    init(_ frame: ARFrame) {
        timestamp = frame.timestamp
        camera = FrameCamera(frame.camera)
        tracking = frame.camera.trackingState
        depth = frame.sceneDepth.flatMap { DepthMap(depth: $0.depthMap, confidence: $0.confidenceMap) }
        image = frame.capturedImage
    }
}
