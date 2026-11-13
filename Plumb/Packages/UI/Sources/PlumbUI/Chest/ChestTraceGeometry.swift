import CoreGraphics

/// Where the chest trace and its band sit inside the trace's bounds.
///
/// The values are evenly spaced in time, oldest at the left edge and newest at the right.
/// Zero millimetres runs across the middle and up is up, at one fixed scale.
struct ChestTraceGeometry: Equatable {
    let plot: CGRect
    let fullScaleMM: Double

    init(size: CGSize, fullScaleMM: Double = Theme.chest.fullScaleMM) {
        plot = CGRect(origin: .zero, size: size)
        self.fullScaleMM = fullScaleMM
    }

    /// The x of value `index` out of `count`.
    func x(index: Int, count: Int) -> CGFloat {
        guard count > 1 else { return plot.maxX }
        return plot.minX + plot.width * CGFloat(index) / CGFloat(count - 1)
    }

    /// The y of a height in millimetres. Beyond full scale it falls outside the plot and is cut off there.
    func y(_ mm: Double) -> CGFloat {
        plot.midY - CGFloat(mm / fullScaleMM) * plot.height
    }

    /// The line as runs of points, broken wherever nothing was measured.
    /// A single measured value between gaps is no line, and is left out.
    func runs(_ values: [Double?]) -> [[CGPoint]] {
        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        for (index, value) in values.enumerated() {
            if let value {
                current.append(CGPoint(x: x(index: index, count: values.count), y: y(value)))
            } else {
                if current.count > 1 { runs.append(current) }
                current = []
            }
        }
        if current.count > 1 { runs.append(current) }
        return runs
    }

    /// The band: the right-hand `share` of the width, between its two heights.
    func bandRect(_ band: ClosedRange<Double>, share: Double) -> CGRect {
        let share = CGFloat(min(max(share, 0), 1))
        let minX = plot.maxX - plot.width * share
        let top = y(band.upperBound)
        return CGRect(x: minX, y: top, width: plot.maxX - minX, height: y(band.lowerBound) - top)
    }
}
