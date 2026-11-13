import Foundation

/// The part of the grid that stands out from the surface behind it.
struct ProudObject: Sendable {
    /// How many grid columns it spans.
    var columns: Int
    /// How many grid rows it spans.
    var rows: Int
    /// Typical depth of its surface, in metres.
    var distanceM: Double
    /// Typical distance it stands out from the surface behind, in metres.
    var reliefM: Double
    /// True when it reaches the edge of the grid, so the grid cannot show where it ends.
    var touchesEdge: Bool
}

/// A probe's depth readings with the grid geometry worked out once.
struct DepthGrid {
    /// A smaller grid cannot show both an object and the surface around it.
    private static let minimumSide = 8

    let width: Int
    let height: Int
    /// Row by row from the top-left. NaN where the sensor had no reading.
    private let depths: [Double]

    /// Nil when the probe does not describe a usable grid.
    init?(_ probe: SceneProbe) {
        guard probe.gridWidth >= Self.minimumSide, probe.gridHeight >= Self.minimumSide,
              probe.depthsM.count == probe.gridWidth * probe.gridHeight,
              probe.focalLengthPx.isFinite, probe.focalLengthPx > 0,
              probe.patchWidthPx.isFinite, probe.patchWidthPx > 0,
              probe.patchHeightPx.isFinite, probe.patchHeightPx > 0 else { return nil }
        width = probe.gridWidth
        height = probe.gridHeight
        depths = probe.depthsM.map { $0.isFinite && $0 > 0 ? $0 : .nan }
    }

    /// Share of cells that hold a reading, 0...1.
    var validFraction: Double {
        Double(depths.filter(\.isFinite).count) / Double(depths.count)
    }

    /// Typical depth of the middle third of the grid: the surface at the proposed point itself.
    var centreDepth: Double? {
        let columns = (width / 3)..<(width - width / 3), rows = (height / 3)..<(height - height / 3)
        return samples { columns.contains($0) && rows.contains($1) }.map(\.depth).median
    }

    /// Every reading in the grid.
    var readings: [PlaneSample] {
        samples { _, _ in true }
    }

    /// The readings in the outer band of the grid: the surface around whatever is in the middle.
    func border(fraction: Double) -> [PlaneSample] {
        let bandX = max(1, Int((Double(width) * fraction).rounded()))
        let bandY = max(1, Int((Double(height) * fraction).rounded()))
        return samples { column, row in
            column < bandX || column >= width - bandX || row < bandY || row >= height - bandY
        }
    }

    /// The connected patch of cells standing at least `threshold` metres in front of the surface
    /// that lies nearest the centre of the grid. Nil when nothing stands out at the proposed point.
    func proudObject(inFrontOf surface: InversePlane, threshold: Double) -> ProudObject? {
        var proud = [Double](repeating: -.infinity, count: depths.count)
        for row in 0..<height {
            for column in 0..<width {
                if let sample = sample(column: column, row: row) {
                    proud[row * width + column] = surface.proudness(of: sample)
                }
            }
        }
        // The model's point should be on the object. A patch well away from it is something else.
        let reach = max(1.5, Double(min(width, height)) / 8)
        let centreColumn = Double(width - 1) / 2, centreRow = Double(height - 1) / 2

        var visited = [Bool](repeating: false, count: depths.count)
        var best: (cells: [Int], gap: Double)?
        for start in depths.indices where proud[start] >= threshold && !visited[start] {
            var cells: [Int] = []
            var gap = Double.infinity
            var stack = [start]
            visited[start] = true
            while let cell = stack.popLast() {
                cells.append(cell)
                let column = cell % width, row = cell / width
                gap = min(gap, hypot(Double(column) - centreColumn, Double(row) - centreRow))
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nextColumn = column + dx, nextRow = row + dy
                    guard (0..<width).contains(nextColumn), (0..<height).contains(nextRow) else { continue }
                    let next = nextRow * width + nextColumn
                    if proud[next] >= threshold, !visited[next] {
                        visited[next] = true
                        stack.append(next)
                    }
                }
            }
            if gap <= reach, gap < (best?.gap ?? .infinity) {
                best = (cells, gap)
            }
        }
        guard let cells = best?.cells,
              let distance = cells.map({ depths[$0] }).median,
              let relief = cells.map({ proud[$0] }).median else { return nil }
        let columns = cells.map { $0 % width }, rows = cells.map { $0 / width }
        let left = columns.min() ?? 0, right = columns.max() ?? 0
        let top = rows.min() ?? 0, bottom = rows.max() ?? 0
        return ProudObject(columns: right - left + 1, rows: bottom - top + 1, distanceM: distance, reliefM: relief,
                           touchesEdge: left == 0 || top == 0 || right == width - 1 || bottom == height - 1)
    }

    // MARK: - Private

    /// The reading in one cell, placed on a -1...1 scale so the plane fit stays well conditioned at
    /// any grid size. Nil where the sensor had no reading.
    private func sample(column: Int, row: Int) -> PlaneSample? {
        let depth = depths[row * width + column]
        guard depth.isFinite else { return nil }
        return PlaneSample(u: 2 * Double(column) / Double(width - 1) - 1,
                           v: 2 * Double(row) / Double(height - 1) - 1, depth: depth)
    }

    private func samples(where include: (_ column: Int, _ row: Int) -> Bool) -> [PlaneSample] {
        var found: [PlaneSample] = []
        for row in 0..<height {
            for column in 0..<width where include(column, row) {
                if let sample = sample(column: column, row: row) {
                    found.append(sample)
                }
            }
        }
        return found
    }
}
