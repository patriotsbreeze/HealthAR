import CoreGraphics
import Foundation
import simd

/// The maths of the AED edge pointer: whether the marker is in sight, and when it is not, where on
/// the picture's edge a chevron points toward it, which way, and the words beside it.
///
/// View points are the camera view's own, x to the right and y down, as `ARView.project` gives them.
enum EdgePointer {
    /// Where the chevron goes and which way it points.
    struct Placement: Sendable, Equatable {
        /// Centre of the chevron, in view points.
        var position: CGPoint
        /// Direction it points, in radians from the view's +x turning toward its +y (down the screen).
        var angle: CGFloat
    }

    /// The pointer for one frame, or nil when the marker is in sight and needs none.
    ///
    /// `marks` are the marker's points that count as seeing it (its foot and its disc); it is in
    /// sight when one of them is in front of the camera and projects inside `view`. Otherwise the
    /// chevron sits on the border of `edge` and points toward `target`. `camera` is the camera's
    /// position and `forward` the unit direction it looks; `project` turns a world point in front
    /// of the camera into a view point, as `ARView.project` does. Nil too when that projection fails.
    static func place(toward target: SIMD3<Float>, marks: [SIMD3<Float>], camera: SIMD3<Float>,
                      forward: SIMD3<Float>, view: CGRect, edge: CGRect,
                      project: (SIMD3<Float>) -> CGPoint?) -> Placement? {
        let inSight = marks.contains { mark in
            simd_dot(mark - camera, forward) > 0 && (project(mark).map { view.contains($0) } ?? false)
        }
        guard !inSight, let seen = project(inFront(target, camera: camera, forward: forward)) else { return nil }
        return onEdge(toward: seen, of: edge)
    }

    /// `point` when it is in front of the camera; for a point behind it, or level with the lens,
    /// its mirror image in front: the same offsets sideways and up, with the distance ahead made
    /// positive. That projects on the side of the picture the phone would have to turn toward.
    static func inFront(_ point: SIMD3<Float>, camera: SIMD3<Float>, forward: SIMD3<Float>) -> SIMD3<Float> {
        let offset = point - camera
        let ahead = simd_dot(offset, forward)
        guard ahead < minAheadM else { return point }
        return camera + (offset - forward * ahead) + forward * max(-ahead, minAheadM)
    }

    /// Where the line from the middle of `edge` toward `point` crosses the border of `edge`, and
    /// that line's direction. A point at the very middle, which is what an AED dead behind the
    /// camera gives, is pointed at straight down.
    static func onEdge(toward point: CGPoint, of edge: CGRect) -> Placement {
        let middle = CGPoint(x: edge.midX, y: edge.midY)
        var dx = point.x - middle.x
        var dy = point.y - middle.y
        if hypot(dx, dy) < 1e-6 {
            dx = 0
            dy = 1
        }
        let reach = min(dx == 0 ? .infinity : edge.width / 2 / abs(dx),
                        dy == 0 ? .infinity : edge.height / 2 / abs(dy))
        return Placement(position: CGPoint(x: middle.x + dx * reach, y: middle.y + dy * reach), angle: atan2(dy, dx))
    }

    /// The words beside the chevron, such as "AED 4.2 m": tenths of a metre below 10 m, whole metres beyond.
    static func words(distanceM: Float) -> String {
        distanceM < 9.95 ? String(format: "AED %.1f m", distanceM) : String(format: "AED %.0f m", distanceM)
    }

    /// Where words of `size` go: beside the chevron on the side away from the edge it points at,
    /// level with it when it points mostly sideways, and centred over or under it when it points
    /// mostly up or down. `clearance` runs from the chevron's centre to the nearer side of the
    /// words. Kept wholly inside `bounds` where they fit.
    static func wordsFrame(size: CGSize, beside placement: Placement, clearance: CGFloat,
                           within bounds: CGRect) -> CGRect {
        let dx = cos(placement.angle)
        let dy = sin(placement.angle)
        var centre = placement.position
        if abs(dx) >= abs(dy) {
            centre.x -= (dx > 0 ? 1 : -1) * (clearance + size.width / 2)
        } else {
            centre.y -= (dy > 0 ? 1 : -1) * (clearance + size.height / 2)
        }
        let x = min(max(centre.x - size.width / 2, bounds.minX), bounds.maxX - size.width)
        let y = min(max(centre.y - size.height / 2, bounds.minY), bounds.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Nearest a mirrored point is put in front of the lens, in metres, so it never projects to infinity.
    private static let minAheadM: Float = 0.01
}
