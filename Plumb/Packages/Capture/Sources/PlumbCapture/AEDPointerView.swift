import UIKit

/// The small green chevron at the picture's edge that points the way to an AED out of sight, with
/// its distance in plain words beside it. Drawn flat over the camera picture, never in the world,
/// and lets every touch through to the picture beneath. Main thread only.
final class AEDPointerView: UIView {
    /// Gap between the picture's edge, inside the safe area, and the chevron's centre, in points.
    static let edgeMarginPt: CGFloat = 22
    /// Side of the square the chevron is drawn in, in points.
    static let chevronSidePt: CGFloat = 20

    let chevron = ChevronView(side: chevronSidePt)
    let words = PlateLabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isHidden = true
        words.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        words.textColor = GuideColours.aed
        words.backgroundColor = GuideColours.ground.withAlphaComponent(0.85)
        addSubview(chevron)
        addSubview(words)
    }

    @available(*, unavailable, message: "Built in code only")
    required init?(coder: NSCoder) {
        nil
    }

    /// Where the chevron's centre may sit: inside the safe area, less the margin.
    var edge: CGRect {
        bounds.inset(by: safeAreaInsets).insetBy(dx: Self.edgeMarginPt, dy: Self.edgeMarginPt)
    }

    /// Shows the chevron at `placement` and `text` beside it.
    func show(_ placement: EdgePointer.Placement, text: String) {
        chevron.center = placement.position
        chevron.transform = CGAffineTransform(rotationAngle: placement.angle)
        words.text = text
        words.frame = EdgePointer.wordsFrame(size: words.intrinsicContentSize, beside: placement,
                                             clearance: Self.chevronSidePt / 2 + 4,
                                             within: bounds.inset(by: safeAreaInsets))
        isHidden = false
    }

    /// Hides the chevron and its words.
    func hide() {
        isHidden = true
    }
}

/// A chevron pointing along +x: green, with a thin dark edge so it reads on a bright picture too.
final class ChevronView: UIView {
    init(side: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        isUserInteractionEnabled = false
        let path = UIBezierPath()
        path.move(to: CGPoint(x: side * 0.3, y: side * 0.15))
        path.addLine(to: CGPoint(x: side * 0.7, y: side * 0.5))
        path.addLine(to: CGPoint(x: side * 0.3, y: side * 0.85))
        for (colour, width) in [(GuideColours.ground, CGFloat(6.5)), (GuideColours.aed, CGFloat(3.5))] {
            let stroke = CAShapeLayer()
            stroke.path = path.cgPath
            stroke.fillColor = nil
            stroke.strokeColor = colour.cgColor
            stroke.lineWidth = width
            stroke.lineCap = .round
            stroke.lineJoin = .round
            layer.addSublayer(stroke)
        }
    }

    @available(*, unavailable, message: "Built in code only")
    required init?(coder: NSCoder) {
        nil
    }
}

/// A label on a plain square plate, with room round the words.
final class PlateLabel: UILabel {
    private static let insets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: Self.insets))
    }

    override var intrinsicContentSize: CGSize {
        let words = super.intrinsicContentSize
        return CGSize(width: words.width + Self.insets.left + Self.insets.right,
                      height: words.height + Self.insets.top + Self.insets.bottom)
    }
}
