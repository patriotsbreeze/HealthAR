import Foundation
import PlumbGeometry

/// One frame's LiDAR depth map and its confidence, copied into memory this package owns so
/// nothing of the camera frame has to be kept.
struct DepthMap: Sendable, Equatable {
    /// Cells per row.
    let width: Int
    /// Number of rows.
    let height: Int
    /// Planar depth of each cell in metres, row by row from the top-left.
    let depthsM: [Float]
    /// Confidence of each cell, 0 low, 1 medium, 2 high. Empty when the sensor gave none.
    let confidence: [UInt8]

    /// Wraps cells already in row-major order. A confidence list of the wrong length is dropped.
    init(width: Int, height: Int, depthsM: [Float], confidence: [UInt8] = []) {
        precondition(width >= 0 && height >= 0 && depthsM.count == width * height,
                     "A depth map holds width * height depths")
        self.width = width
        self.height = height
        self.depthsM = depthsM
        self.confidence = confidence.count == depthsM.count ? confidence : []
    }

    /// Cuts `window` out of the map. Cells beyond the map's edges come back as no reading
    /// (not-a-number, confidence 0), so the patch keeps its size and stays centred where asked.
    func cut(_ window: CellWindow) -> DepthPatch {
        let columns = max(window.columns, 0)
        let rows = max(window.rows, 0)
        var depths = [Float](repeating: .nan, count: columns * rows)
        var levels = [UInt8](repeating: 0, count: confidence.isEmpty ? 0 : columns * rows)
        // The part of the window that lies on the map; everything else stays "no reading".
        let firstColumn = max(window.column, 0)
        let endColumn = min(window.column + columns, width)
        let firstRow = max(window.row, 0)
        let endRow = min(window.row + rows, height)
        if firstColumn < endColumn, firstRow < endRow {
            for row in firstRow..<endRow {
                let source = row * width
                let target = (row - window.row) * columns - window.column
                for column in firstColumn..<endColumn {
                    depths[target + column] = depthsM[source + column]
                    if !levels.isEmpty { levels[target + column] = confidence[source + column] }
                }
            }
        }
        return DepthPatch(width: columns, height: rows, depthsM: depths, confidence: levels)
    }

    /// The median depth, in metres, of the usable cells in `window`: finite, above zero and at least
    /// `minConfidence`. Nil when there are none.
    func medianDepth(in window: CellWindow, minConfidence: UInt8) -> Double? {
        let patch = cut(window)
        var usable: [Double] = []
        for index in patch.depthsM.indices {
            let level = patch.confidence.isEmpty ? Self.highConfidence : patch.confidence[index]
            if let depth = Self.usable(patch.depthsM[index], level: level, minConfidence: minConfidence) {
                usable.append(depth)
            }
        }
        guard !usable.isEmpty else { return nil }
        usable.sort()
        let middle = usable.count / 2
        return usable.count % 2 == 1 ? usable[middle] : (usable[middle - 1] + usable[middle]) / 2
    }

    /// The depth of one cell in metres when it is a usable reading: on the map, finite, above zero
    /// and at least `minConfidence`. Nil otherwise.
    func depthM(column: Int, row: Int, minConfidence: UInt8) -> Double? {
        guard (0..<width).contains(column), (0..<height).contains(row) else { return nil }
        let index = row * width + column
        let level = confidence.isEmpty ? Self.highConfidence : confidence[index]
        return Self.usable(depthsM[index], level: level, minConfidence: minConfidence)
    }

    /// A depth in metres when it is finite, above zero and at least `minConfidence`; nil otherwise.
    private static func usable(_ depth: Float, level: UInt8, minConfidence: UInt8) -> Double? {
        let metres = Double(depth)
        return level >= minConfidence && metres.isFinite && metres > 0 ? metres : nil
    }

    /// The level given to cells of a map that carries no confidence, matching `DepthPatch`.
    private static let highConfidence: UInt8 = 2
}
