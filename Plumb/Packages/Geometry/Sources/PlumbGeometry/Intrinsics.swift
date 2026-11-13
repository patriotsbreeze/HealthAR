import Foundation

/// The pinhole numbers of the captured image: how strongly the lens magnifies and where its axis lands.
///
/// Image pixels run u to the right and v downward, from the top-left corner of the sensor's
/// native landscape image. All four lens values are in those pixels.
public struct Intrinsics: Sendable, Codable, Equatable {
    /// Focal length along u, in pixels.
    public var fx: Double
    /// Focal length along v, in pixels.
    public var fy: Double
    /// The u coordinate where the lens axis meets the image.
    public var cx: Double
    /// The v coordinate where the lens axis meets the image.
    public var cy: Double
    /// Image width in pixels.
    public var width: Int
    /// Image height in pixels.
    public var height: Int

    /// Builds intrinsics from the lens values and the image size they belong to.
    public init(fx: Double, fy: Double, cx: Double, cy: Double, width: Int, height: Int) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.width = width
        self.height = height
    }
}
