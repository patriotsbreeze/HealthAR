import ARKit
import Foundation
import PlumbGeometry

/// The camera of one frame: its lens values and where it stood. Copied out of the ARFrame.
struct FrameCamera: Sendable, Equatable {
    var intrinsics: Intrinsics
    var pose: CameraPose
}

extension FrameCamera {
    /// Copies the lens values and pose of an ARKit camera.
    ///
    /// ARKit's intrinsics and transform refer to the captured image in the sensor's native
    /// landscape orientation, whatever way the interface is turned: the same image, u right and
    /// v down, that the depth map and the luma plane are in.
    init(_ camera: ARCamera) {
        // Column-major: column 0 holds fx, column 1 holds fy, column 2 holds (cx, cy, 1).
        let k = camera.intrinsics
        intrinsics = Intrinsics(fx: Double(k.columns.0.x), fy: Double(k.columns.1.y),
                                cx: Double(k.columns.2.x), cy: Double(k.columns.2.y),
                                width: Int(camera.imageResolution.width.rounded()),
                                height: Int(camera.imageResolution.height.rounded()))
        pose = CameraPose(camera.transform)
    }
}
