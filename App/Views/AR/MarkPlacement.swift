import CoreGraphics
import SwiftUI

/// The band between the panels, in global points. It's all of the camera that can be seen and tapped.
struct FreeCameraArea: PreferenceKey {
    static let defaultValue = CGRect.zero
    /// Only the band sets this, and the views around it would each hand back the default.
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != defaultValue { value = next }
    }
}

/// Where an AR mark goes when the panels leave only part of the screen. On a spot that can't be seen,
/// it sits at the nearest place that can and points the way.
struct MarkPlacement: Equatable {
    private static let edgeMargin: CGFloat = 4

    var center: CGPoint
    /// Radians, 0 pointing right and positive turning clockwise.
    var angle: Double
    /// Drawn on the thing itself, not pointing at it from somewhere else.
    var isOnTarget: Bool

    /// - Parameters:
    ///   - position: Normalized view coordinates, as vision gives them.
    ///   - free: Nil leaves the mark where it falls.
    ///   - column: Where in the band the mark's center can't go, because what's under it matters more.
    static func place(
        position: CGPoint,
        isOnScreen: Bool,
        angle: Double,
        view: CGSize,
        free: CGRect?,
        size: CGSize,
        keepingOff column: ClosedRange<CGFloat>? = nil
    ) -> MarkPlacement {
        let point = CGPoint(x: position.x * view.width, y: position.y * view.height)
        guard let free else { return MarkPlacement(center: point, angle: angle, isOnTarget: isOnScreen) }
        let center = clamp(point, size: size, into: free)
        if let column, column.contains(center.x) {
            // Beside it, on the side the mark points to.
            let right = isOnScreen ? point.x >= (column.lowerBound + column.upperBound) / 2 : cos(angle) >= 0
            let beside = clamp(CGPoint(x: right ? column.upperBound : column.lowerBound, y: center.y), size: size, into: free)
            let direction = isOnScreen ? atan2(point.y - beside.y, point.x - beside.x) : angle
            return MarkPlacement(center: beside, angle: direction, isOnTarget: false)
        }
        if isOnScreen, free.contains(point) { return MarkPlacement(center: center, angle: angle, isOnTarget: true) }
        // Vision's angle runs from the view's center, which is no use once the mark has moved.
        let direction = isOnScreen ? atan2(point.y - center.y, point.x - center.x) : angle
        return MarkPlacement(center: center, angle: direction, isOnTarget: false)
    }

    /// Under the mark if there's room, otherwise over it, and inside the free area either way.
    static func labelCenter(mark: CGPoint, markHeight: CGFloat, label: CGSize, free: CGRect?) -> CGPoint {
        let gap = markHeight / 2 + 2 + label.height / 2
        guard let free else { return CGPoint(x: mark.x, y: mark.y + gap) }
        let fitsBelow = mark.y + gap + label.height / 2 <= free.maxY
        return clamp(CGPoint(x: mark.x, y: fitsBelow ? mark.y + gap : mark.y - gap), size: label, into: free)
    }

    /// With no room in the band, nothing draws at all, rather than sit over the buttons. Nil means no band.
    static func hasRoom(for height: CGFloat, in free: CGRect?) -> Bool {
        free.map { $0.height >= height } ?? true
    }

    /// A space smaller than the mark centers it, since nothing can keep it inside. Callouts use it too.
    static func clamp(_ point: CGPoint, size: CGSize, into free: CGRect) -> CGPoint {
        let inner = free.insetBy(dx: min(size.width + edgeMargin * 2, free.width) / 2, dy: min(size.height, free.height) / 2)
        return CGPoint(x: min(max(point.x, inner.minX), inner.maxX), y: min(max(point.y, inner.minY), inner.maxY))
    }
}
