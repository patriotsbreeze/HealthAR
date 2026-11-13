import Foundation

/// A place in a camera frame where a model says an object is. A guess until the sensors agree.
public struct ScenePoint: Sendable, Equatable {
    /// 0 at the left edge of the frame, 1 at the right.
    public var x: Double
    /// 0 at the top edge of the frame, 1 at the bottom.
    public var y: Double
    /// What the model called the object.
    public var label: String

    /// Creates a point from frame-relative coordinates.
    public init(x: Double, y: Double, label: String) {
        self.x = x
        self.y = y
        self.label = label
    }
}

/// A rectangle inside the camera frame, in the same 0...1 units as `ScenePoint`.
public struct SceneRegion: Sendable, Equatable {
    /// Left edge, 0...1.
    public var x: Double
    /// Top edge, 0...1.
    public var y: Double
    /// Width as a share of the frame's width, 0...1.
    public var width: Double
    /// Height as a share of the frame's height, 0...1.
    public var height: Double

    /// Creates a region from frame-relative edges and sizes.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The whole frame.
    public static let full = SceneRegion(x: 0, y: 0, width: 1, height: 1)

    /// A region `factor` times smaller on each side, centred on the point as nearly as the frame allows.
    public static func zoomed(around point: ScenePoint, factor: Double) -> SceneRegion {
        let side = 1 / max(1, factor)
        let left = min(max(point.x - side / 2, 0), 1 - side)
        let top = min(max(point.y - side / 2, 0), 1 - side)
        return SceneRegion(x: left, y: top, width: side, height: side)
    }

    /// Converts a point given relative to this region into a point relative to the whole frame.
    public func inFullFrame(_ point: ScenePoint) -> ScenePoint {
        ScenePoint(x: x + point.x * width, y: y + point.y * height, label: point.label)
    }
}
