import Foundation
import PlumbGeometry

/// The closest honest stand-in for the same phone without LiDAR.
///
/// Neither height method can run without a range: along the line of sight the height IS the LiDAR
/// range, and the picture slide needs the range to turn pixels into millimetres. So this keeps the
/// picture method and takes the range away. Each frame's hands depth patch is replaced by a flat one
/// at the assumed distance along the line of sight through the hands, and the still reference patch
/// is dropped. The pose, the lens values, the hands' pixel and the brightness grid stay as recorded.
///
/// That is kind to the camera-only case: on a LiDAR phone ARKit's own tracking may lean on the depth
/// sensor, and the hands box was placed using depth. Quality comes from the picture match alone,
/// since there is no depth to judge.
public enum CameraOnly {
    /// `frame` with every LiDAR reading replaced by the assumed range.
    public static func frame(_ frame: TraceFrame, assumedRangeM: Double) -> TraceFrame {
        var stripped = frame
        let depthM = planarDepth(ofRange: assumedRangeM, atU: frame.handsU, v: frame.handsV,
                                 intrinsics: frame.intrinsics)
        // Empty confidence counts every sample as high; one flat surface has no spread to doubt.
        stripped.hands = DepthPatch(width: side, height: side,
                                    depthsM: [Float](repeating: Float(depthM), count: side * side), confidence: [])
        stripped.reference = nil
        stripped.referenceU = nil
        stripped.referenceV = nil
        return stripped
    }

    /// The planar depth, along the lens axis, of a point `rangeM` metres from the camera on the line
    /// of sight through pixel (u, v).
    static func planarDepth(ofRange rangeM: Double, atU u: Double, v: Double, intrinsics: Intrinsics) -> Double {
        let across = (u - intrinsics.cx) / intrinsics.fx
        let down = (v - intrinsics.cy) / intrinsics.fy
        return rangeM / (1 + across * across + down * down).squareRoot()
    }

    /// Samples along each side of the flat patch: enough for the estimator to count it as a surface.
    private static let side = 4
}
