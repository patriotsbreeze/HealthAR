import CoreGraphics
import Foundation

/// Which pixels of a picture are to be hidden, one flag a pixel, row by row from the top-left.
/// Every step only ever adds hidden pixels: nothing here can uncover one.
struct PeopleMask: Sendable, Equatable {
    /// Picture width in pixels.
    let width: Int
    /// Picture height in pixels.
    let height: Int
    /// True for each pixel to be hidden.
    private(set) var hidden: [Bool]

    /// Hides every pixel of a `width` x `height` picture where a person coverage grid reads at
    /// least `threshold`. The grid, `coverageWidth` x `coverageHeight` values from 0 (no one) to
    /// 255 (a person), row by row from the top-left, is stretched over the whole picture, and each
    /// pixel reads the grid value under its centre. Nil when either size is not above zero or the
    /// grid does not hold exactly that many values.
    init?(coverage: [UInt8], coverageWidth: Int, coverageHeight: Int, threshold: UInt8, width: Int, height: Int) {
        guard width > 0, height > 0, coverageWidth > 0, coverageHeight > 0,
              coverage.count == coverageWidth * coverageHeight else { return nil }
        self.width = width
        self.height = height
        // The grid cell under each pixel centre: a centre at x + 0.5 lies in cell floor((x + 0.5) * scale).
        let columns = (0..<width).map { min((2 * $0 + 1) * coverageWidth / (2 * width), coverageWidth - 1) }
        let rows = (0..<height).map { min((2 * $0 + 1) * coverageHeight / (2 * height), coverageHeight - 1) }
        var hidden = [Bool](repeating: false, count: width * height)
        for (y, row) in rows.enumerated() {
            for (x, column) in columns.enumerated() where coverage[row * coverageWidth + column] >= threshold {
                hidden[y * width + x] = true
            }
        }
        self.hidden = hidden
    }

    /// Share of the picture hidden, 0...1.
    var hiddenFraction: Double {
        Double(hidden.lazy.filter { $0 }.count) / Double(hidden.count)
    }

    /// Grows every hidden area by `radius` pixels in every direction, a square at a time, so the soft
    /// edge of a person never shows. Nothing changes when `radius` is not above zero.
    mutating func grow(by radius: Int) {
        guard radius > 0 else { return }
        // Past the picture's longer side every radius hides the same; the cap keeps the sums from overflowing.
        let radius = min(radius, max(width, height))
        // A square grows as a run across each row and then a run down each column.
        var line: [Bool] = []
        for row in 0..<height {
            Self.spread(&hidden, start: row * width, count: width, step: 1, radius: radius, line: &line)
        }
        for column in 0..<width {
            Self.spread(&hidden, start: column, count: height, step: width, radius: radius, line: &line)
        }
    }

    /// Hides every pixel of `box`, in pixels from the top-left; the part off the picture is ignored,
    /// and so is a box without finite edges.
    mutating func hide(_ box: CGRect) {
        guard box.hasFiniteEdges else { return }
        let kept = box.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard kept.width >= 1, kept.height >= 1 else { return }
        let columns = Int(kept.minX)..<Int(kept.maxX)
        for row in Int(kept.minY)..<Int(kept.maxY) {
            for column in columns { hidden[row * width + column] = true }
        }
    }

    /// A face box grown by `margin` times its width on the left and right and its height above and
    /// below, rounded out to whole pixels and cut to a picture of `size`. Face detectors box the
    /// face tightly, leaving out hair, ears and the chin's edge. Nil when the box has no finite
    /// edges or no pixel of it is left on the picture.
    static func faceBox(_ box: CGRect, margin: Double, within size: CGSize) -> CGRect? {
        guard box.hasFiniteEdges else { return nil }
        let grown = box.insetBy(dx: -box.width * margin, dy: -box.height * margin)
        let kept = grown.integral.intersection(CGRect(origin: .zero, size: size))
        guard kept.width >= 1, kept.height >= 1 else { return nil }
        return kept
    }

    /// Marks each of `count` flags, `step` apart from `start`, that lies within `radius` of one
    /// marked before the call. `line` is scratch space, reused so a whole mask needs only one.
    private static func spread(_ flags: inout [Bool], start: Int, count: Int, step: Int, radius: Int,
                               line: inout [Bool]) {
        line.removeAll(keepingCapacity: true)
        for index in 0..<count { line.append(flags[start + index * step]) }
        // How many marked flags lie in the window [index - radius, index + radius].
        var marked = line.prefix(radius).lazy.filter { $0 }.count
        for index in 0..<count {
            if index + radius < count, line[index + radius] { marked += 1 }
            if index - radius - 1 >= 0, line[index - radius - 1] { marked -= 1 }
            flags[start + index * step] = marked > 0
        }
    }
}

extension CGRect {
    /// True when every edge is a finite number. False for the null rectangle, whose origin is
    /// infinite, and for one holding not-a-number, which rectangle maths does not reliably reject.
    var hasFiniteEdges: Bool {
        [minX, minY, maxX, maxY].allSatisfy(\.isFinite)
    }
}
