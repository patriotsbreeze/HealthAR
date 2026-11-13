import CoreVideo
import Foundation

extension DepthMap {
    /// Copies ARKit's depth map (32-bit float metres) and, when given, its confidence map (one byte
    /// per cell, ARConfidenceLevel's raw values 0, 1, 2). Nil when the depth map is not 32-bit float
    /// depth or cannot be read. A confidence map of another format or size is left out.
    init?(depth: CVPixelBuffer, confidence: CVPixelBuffer?) {
        guard let map = PlaneView.reading(depth, plane: nil, formats: [kCVPixelFormatType_DepthFloat32], {
            (width: $0.width, height: $0.height, depths: $0.samples(of: Float.self))
        }), map.depths.count == map.width * map.height, !map.depths.isEmpty else { return nil }
        let levels = confidence.flatMap {
            PlaneView.reading($0, plane: nil, formats: [kCVPixelFormatType_OneComponent8]) { view in
                view.width == map.width && view.height == map.height ? view.samples(of: UInt8.self) : []
            }
        }
        self.init(width: map.width, height: map.height, depthsM: map.depths, confidence: levels ?? [])
    }
}
