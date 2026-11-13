import CoreGraphics

/// Where a chip goes beside the thing it names, using the same clamp as every other mark, so it stays
/// in the band. `place`, `labelCenter` and `hasRoom` are untouched.
extension MarkPlacement {
    enum Side: CaseIterable, Equatable {
        case right, left, below, above
    }

    static let calloutOrder: [Side] = [.right, .left, .below, .above]

    /// The first side where the chip covers nothing, starting with the side it had last frame, so it
    /// doesn't hop about. Where every side covers something, the one covering least, counting how far
    /// the clamp had to move it, with the area it still covers, so a caller can leave the chip out.
    /// With no band, a chip falls where it falls.
    static func chipCenter(
        item: CGRect,
        chip: CGSize,
        free: CGRect?,
        avoiding obstacles: [CGRect],
        previous: Side?,
        order: [Side] = calloutOrder,
        gap: CGFloat = DS.AR.chipGap
    ) -> (center: CGPoint, side: Side, covered: CGFloat) {
        let candidates = (previous.map { [$0] } ?? []) + order.filter { $0 != previous }
        var best: (center: CGPoint, side: Side, score: CGFloat, covered: CGFloat)?
        for side in candidates {
            let wanted = outside(item, side: side, chip: chip, gap: gap)
            let center = free.map { clamp(wanted, size: chip, into: $0) } ?? wanted
            let rect = CGRect(center: center, size: chip)
            let covered = (obstacles + [item]).reduce(CGFloat(0)) { $0 + overlap(rect, $1) }
            let score = covered + 0.5 * hypot(center.x - wanted.x, center.y - wanted.y)
            if score == 0 { return (center, side, 0) }
            if best.map({ score < $0.score }) ?? true { best = (center, side, score, covered) }
        }
        return best.map { ($0.center, $0.side, $0.covered) } ?? (CGPoint(x: item.midX, y: item.midY), .right, 0)
    }

    private static func outside(_ item: CGRect, side: Side, chip: CGSize, gap: CGFloat) -> CGPoint {
        switch side {
        case .right: CGPoint(x: item.maxX + gap + chip.width / 2, y: item.midY)
        case .left: CGPoint(x: item.minX - gap - chip.width / 2, y: item.midY)
        case .below: CGPoint(x: item.midX, y: item.maxY + gap + chip.height / 2)
        case .above: CGPoint(x: item.midX, y: item.minY - gap - chip.height / 2)
        }
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        guard !b.isNull, !b.isEmpty, a.intersects(b) else { return 0 }
        let both = a.intersection(b)
        return both.width * both.height
    }
}
