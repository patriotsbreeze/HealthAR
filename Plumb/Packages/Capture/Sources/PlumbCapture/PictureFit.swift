import CoreGraphics
import Foundation

/// Where the camera picture sits when shown whole (aspect fit) inside a view, and how points move
/// between the view and the picture.
///
/// Picture points are normalised image coordinates: 0...1 across the camera's landscape image,
/// origin at its top-left. The picture is shown upright when the interface is `.landscapeRight`
/// (the sensor's own orientation) and turned half a turn when it is `.landscapeLeft`.
public struct PictureFit: Sendable, Equatable {
    /// Size of the camera image in pixels; only its shape matters.
    public var imageSize: CGSize
    /// Size of the view the picture is shown in, in points.
    public var viewSize: CGSize
    /// True when the picture is shown turned half a turn, as in `.landscapeLeft`.
    public var halfTurn: Bool

    /// Describes a picture of `imageSize` fitted into a view of `viewSize`.
    public init(imageSize: CGSize, viewSize: CGSize, halfTurn: Bool = false) {
        self.imageSize = imageSize
        self.viewSize = viewSize
        self.halfTurn = halfTurn
    }

    /// The largest rectangle of the image's shape that fits the view, centred: where the picture is
    /// drawn. Zero when either size is empty.
    public var pictureFrame: CGRect {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// The picture point under a view point, or nil when the view point is on the bars beside it.
    public func imagePoint(fromViewPoint point: CGPoint) -> CGPoint? {
        let frame = pictureFrame
        guard frame.width > 0, frame.height > 0,
              point.x >= frame.minX, point.x <= frame.maxX, point.y >= frame.minY, point.y <= frame.maxY else {
            return nil
        }
        return turned(CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height))
    }

    /// The view point that shows a picture point.
    public func viewPoint(fromImagePoint point: CGPoint) -> CGPoint {
        let frame = pictureFrame
        let shown = turned(point)
        return CGPoint(x: frame.minX + shown.x * frame.width, y: frame.minY + shown.y * frame.height)
    }

    /// The view rectangle that shows a picture rectangle.
    public func viewRect(fromImageRect rect: CGRect) -> CGRect {
        let one = viewPoint(fromImagePoint: CGPoint(x: rect.minX, y: rect.minY))
        let other = viewPoint(fromImagePoint: CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: min(one.x, other.x), y: min(one.y, other.y),
                      width: abs(other.x - one.x), height: abs(other.y - one.y))
    }

    /// A half turn is its own inverse, so the same flip maps both ways.
    private func turned(_ point: CGPoint) -> CGPoint {
        halfTurn ? CGPoint(x: 1 - point.x, y: 1 - point.y) : point
    }
}
