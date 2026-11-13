import CoreGraphics

/// Decides where the labels of the marks along a lane go, so none runs into a mark, a neighbour or the edge.
/// A label sits beside its mark when there is room, on a line below when there is not, and is left out
/// when no line is free. A mark without a label is still drawn; selecting it shows its sentence.
enum LabelFit {
    struct Placement: Equatable {
        /// The label's leading edge.
        var x: CGFloat
        /// 0 is the line of marks; 1 and up are the lines below it.
        var row: Int
    }

    /// Returns one entry for each mark, nil where its label is left out.
    /// - Parameters:
    ///   - order: mark indices, most important first. Earlier labels get the better places.
    ///   - rows: how many lines there are, counting the line of marks.
    static func placements(marks: [ClosedRange<CGFloat>], labelWidths: [CGFloat], order: [Int], rows: Int,
                           gap: CGFloat, bounds: ClosedRange<CGFloat>) -> [Placement?] {
        var placed = [Placement?](repeating: nil, count: marks.count)
        var taken = [[ClosedRange<CGFloat>]](repeating: [], count: max(rows, 1))
        taken[0] = marks

        for index in order {
            let width = labelWidths[index]
            for row in taken.indices {
                // Beside means just right of the mark. Below, the label starts under its mark,
                // pulled left only as far as the edge demands.
                let x = row == 0
                    ? marks[index].upperBound + gap
                    : min(marks[index].lowerBound, bounds.upperBound - width)
                let isInside = x >= bounds.lowerBound && x + width <= bounds.upperBound
                let isFree = taken[row].allSatisfy { $0.upperBound <= x - gap || $0.lowerBound >= x + width + gap }
                if isInside, isFree {
                    placed[index] = Placement(x: x, row: row)
                    taken[row].append(x...(x + width))
                    break
                }
            }
        }
        return placed
    }
}
