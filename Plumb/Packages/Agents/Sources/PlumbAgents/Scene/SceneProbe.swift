import Foundation

/// What the depth sensor measured around one proposed point.
///
/// The app samples its depth map on a small grid centred on the point, at least 8 cells each way.
/// The grid should be wide enough to show the surface around the object as well as the object:
/// use `patchSidePx` to size it.
public struct SceneProbe: Sendable, Equatable {
    /// Depth along the camera's axis in metres, row by row from the top-left. A value that is not
    /// finite or not above zero means the sensor had no reading there.
    public var depthsM: [Double]
    /// Number of columns in the grid.
    public var gridWidth: Int
    /// Number of rows in the grid.
    public var gridHeight: Int
    /// The camera's focal length, in pixels of the image the grid was cut from.
    public var focalLengthPx: Double
    /// Width of the area the grid covers, in pixels of that image.
    public var patchWidthPx: Double
    /// Height of the area the grid covers, in pixels of that image.
    public var patchHeightPx: Double

    /// Creates a probe from one grid of depth readings and the camera geometry it was cut from.
    public init(depthsM: [Double], gridWidth: Int, gridHeight: Int, focalLengthPx: Double,
                patchWidthPx: Double, patchHeightPx: Double) {
        self.depthsM = depthsM
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.focalLengthPx = focalLengthPx
        self.patchWidthPx = patchWidthPx
        self.patchHeightPx = patchHeightPx
    }

    /// The side, in image pixels, of a square patch that covers the configured real-world span at
    /// this depth. Nil when the depth or focal length is not a usable number.
    public static func patchSidePx(centreDepthM: Double, focalLengthPx: Double,
                                   config: AgentsConfig = AgentsConfig()) -> Double? {
        guard centreDepthM.isFinite, centreDepthM > 0, focalLengthPx.isFinite, focalLengthPx > 0 else { return nil }
        return config.sceneProbeSpanM * focalLengthPx / centreDepthM
    }
}
