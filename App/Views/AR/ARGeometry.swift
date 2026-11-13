import CoreGraphics
import SwiftUI

/// Pure path builders for the AR marks, all in view points. Angles are radians, 0 pointing right and
/// positive turning clockwise on screen, as vision gives them.
enum ARGeometry {
    // MARK: - Body zones

    /// A rounded segment, for a limb and for fingers.
    static func segmentCapsule(from a: CGPoint, to b: CGPoint, width: CGFloat) -> Path {
        let length = hypot(b.x - a.x, b.y - a.y)
        let angle = atan2(b.y - a.y, b.x - a.x)
        let rect = CGRect(x: -width / 2, y: -width / 2, width: length + width, height: width)
        let transform = CGAffineTransform(translationX: a.x, y: a.y).rotated(by: angle)
        return Path(roundedRect: rect, cornerRadius: width / 2, style: .continuous).applying(transform)
    }

    /// A limb, never thinner than a finger can find.
    static func limb(from a: CGPoint, to b: CGPoint, width: CGFloat) -> Path {
        segmentCapsule(from: a, to: b, width: max(width, DS.AR.limbMinWidth))
    }

    /// An ellipse whose long side runs along `axis`.
    static func ellipse(center: CGPoint, axis: Double, halfLength: CGFloat, halfWidth: CGFloat) -> Path {
        let rect = CGRect(x: -halfLength, y: -halfWidth, width: halfLength * 2, height: halfWidth * 2)
        return Path(ellipseIn: rect).applying(CGAffineTransform(translationX: center.x, y: center.y).rotated(by: axis))
    }

    /// A rounded rectangle whose long side runs along `axis`.
    static func orientedRect(center: CGPoint, axis: Double, halfLength: CGFloat, halfWidth: CGFloat, cornerFraction: CGFloat = 0.35) -> Path {
        let rect = CGRect(x: -halfLength, y: -halfWidth, width: halfLength * 2, height: halfWidth * 2)
        let radius = min(halfLength, halfWidth) * 2 * cornerFraction
        return Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
            .applying(CGAffineTransform(translationX: center.x, y: center.y).rotated(by: axis))
    }

    /// The fitted rectangle of four corners along an axis, as vision's chest and pad quads come.
    static func fit(quad: [CGPoint], axis: Double) -> (center: CGPoint, halfLength: CGFloat, halfWidth: CGFloat)? {
        guard !quad.isEmpty else { return nil }
        let center = CGPoint(x: quad.map(\.x).reduce(0, +) / CGFloat(quad.count), y: quad.map(\.y).reduce(0, +) / CGFloat(quad.count))
        let along = CGVector(dx: cos(axis), dy: sin(axis))
        let across = CGVector(dx: -sin(axis), dy: cos(axis))
        var halfLength: CGFloat = 0, halfWidth: CGFloat = 0
        for point in quad {
            let d = CGVector(dx: point.x - center.x, dy: point.y - center.y)
            halfLength = max(halfLength, abs(d.dx * along.dx + d.dy * along.dy))
            halfWidth = max(halfWidth, abs(d.dx * across.dx + d.dy * across.dy))
        }
        return (center, halfLength, halfWidth)
    }

    /// Where to press, never smaller than a fingertip can find.
    static func pressRing(center: CGPoint, radius: CGFloat) -> Path {
        let r = max(radius, DS.AR.pressRingMinRadius)
        return Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    }

    /// A defibrillator pad, portrait at 1:1.4 before it turns.
    static func pad(center: CGPoint, size: CGSize, angle: Double) -> Path {
        let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        return Path(roundedRect: rect, cornerRadius: size.width * 0.18, style: .continuous)
            .applying(CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle))
    }

    // MARK: - Ghost hands

    /// One hand palm down in palm radii, with the heel at the origin and the fingers toward -y.
    static func hand(mirrored: Bool) -> Path {
        var shape = Path(roundedRect: CGRect(x: -0.55, y: -1.0, width: 1.10, height: 1.35), cornerSize: CGSize(width: 0.3, height: 0.3), style: .continuous)
        let fingers: [(CGFloat, CGFloat)] = [(-0.39, -2.02), (-0.13, -2.18), (0.13, -2.10), (0.39, -1.86)]
        for (x, tip) in fingers {
            shape = shape.union(segmentCapsule(from: CGPoint(x: x, y: -0.85), to: CGPoint(x: x, y: tip), width: 0.24))
        }
        shape = shape.union(segmentCapsule(from: CGPoint(x: -0.48, y: -0.30), to: CGPoint(x: -0.86, y: -1.02), width: 0.27))
        return mirrored ? shape.applying(CGAffineTransform(scaleX: -1, y: 1)) : shape
    }

    struct GhostHands {
        /// The whole lower hand. The painter draws it first and the upper hand on a solid base over it.
        var under: Path
        var over: Path
        /// Where the heel of the hand goes, which is the point of it all.
        var heelPad: Path
    }

    /// How far the lower hand turns from the upper one about the shared heel, so its fingers fan out
    /// past the upper hand's and the pair reads as two hands, one on the other, not one hand with a
    /// thumb on each side.
    static let underHandTurn = -30.0 * .pi / 180

    /// Two hands stacked, heel on `heel`, fingers along `fingerAngle`. About 2.6 palm radii long.
    static func ghostHands(heel: CGPoint, fingerAngle: Double, palmRadius: CGFloat) -> GhostHands {
        let over = hand(mirrored: true)
        let under = hand(mirrored: false)
            .applying(CGAffineTransform(rotationAngle: underHandTurn))
            .applying(CGAffineTransform(translationX: 0, y: 0.05))
        let heelPad = Path(ellipseIn: CGRect(x: -0.42, y: -0.26, width: 0.84, height: 0.52))
        // Local (0, -1) lands on (cos a, sin a).
        let transform = CGAffineTransform(translationX: heel.x, y: heel.y)
            .rotated(by: fingerAngle + .pi / 2)
            .scaledBy(x: palmRadius, y: palmRadius)
        return GhostHands(under: under.applying(transform), over: over.applying(transform), heelPad: heelPad.applying(transform))
    }

    /// Fingers lie across the body, on the side away from the person holding the phone, which is
    /// screen-up. With the torso near upright on screen, they point right rather than flip about.
    static func fingerAngle(torsoAxis: Double) -> Double {
        let one = normalized(torsoAxis - .pi / 2)
        let other = normalized(torsoAxis + .pi / 2)
        if abs(sin(one)) < 0.2 { return cos(one) > 0 ? one : other }
        return sin(one) < 0 ? one : other
    }

    static func normalized(_ angle: Double) -> Double {
        atan2(sin(angle), cos(angle))
    }

    // MARK: - Items and pointers

    static func bracketArm(for rect: CGRect) -> CGFloat {
        let arm = min(rect.width, rect.height) * DS.AR.bracketArmFraction
        return min(max(arm, DS.AR.bracketArm.lowerBound), DS.AR.bracketArm.upperBound)
    }

    /// Four L-shaped corners, not a box, so the thing itself stays in view.
    static func brackets(around rect: CGRect) -> Path {
        let arm = min(bracketArm(for: rect), min(rect.width, rect.height) / 2)
        var path = Path()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
        ]
        for (corner, dx, dy) in corners {
            path.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
        }
        return path
    }

    /// The nearest point on a chip's capsule outline, so a leader meets the chip itself and not the
    /// empty corner of its frame.
    static func nearestCapsulePoint(of chip: CGRect, to point: CGPoint) -> CGPoint {
        let radius = min(chip.width, chip.height) / 2
        guard point.x < chip.minX + radius || point.x > chip.maxX - radius else {
            return CGPoint(x: point.x, y: point.y < chip.midY ? chip.minY : chip.maxY)
        }
        let end = CGPoint(x: point.x < chip.midX ? chip.minX + radius : chip.maxX - radius, y: chip.midY)
        let distance = hypot(point.x - end.x, point.y - end.y)
        guard distance > 0 else { return end }
        return CGPoint(x: end.x + (point.x - end.x) / distance * radius, y: end.y + (point.y - end.y) / distance * radius)
    }

    /// The pointer's arrowhead, centered on `center` and aimed along `angle`. Isosceles, with the tip
    /// the sharpest corner by far, so at any angle it can only read one way.
    static func wedge(center: CGPoint, angle: Double) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 13, y: 0))
        path.addLine(to: CGPoint(x: -8, y: 7))
        path.addLine(to: CGPoint(x: -8, y: -7))
        path.closeSubpath()
        return path.applying(CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle))
    }
}
