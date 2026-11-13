import CoreGraphics
import Foundation
import PlumbGeometry

/// A rectangle of depth-map cells: its top-left cell and its size. It may reach past the map's edges.
struct CellWindow: Sendable, Equatable {
    /// Column of the top-left cell.
    var column: Int
    /// Row of the top-left cell.
    var row: Int
    /// Cells across.
    var columns: Int
    /// Cells down.
    var rows: Int
}

/// How image pixels map onto depth-map cells.
///
/// Assumption (ARKit's documented behaviour, checked on the phone): the depth map covers exactly
/// the same view as the captured image at a lower resolution, 256 x 192 cells for 1920 x 1440
/// pixels, with the same orientation. Whole-number image coordinates name pixel centres, as the
/// intrinsics do, and the same holds for cells.
struct DepthCells: Sendable, Equatable {
    /// Captured image size in pixels.
    var imageWidth: Int
    var imageHeight: Int
    /// Depth map size in cells.
    var mapWidth: Int
    var mapHeight: Int

    /// Pairs an image of `intrinsics`' size with a depth map of the given size.
    init(intrinsics: Intrinsics, mapWidth: Int, mapHeight: Int) {
        imageWidth = intrinsics.width
        imageHeight = intrinsics.height
        self.mapWidth = mapWidth
        self.mapHeight = mapHeight
    }

    /// Cells per image pixel across and down.
    var scale: SIMD2<Double> {
        SIMD2(Double(mapWidth) / Double(max(imageWidth, 1)), Double(mapHeight) / Double(max(imageHeight, 1)))
    }

    /// The cell under image pixel (u, v). Not clamped: a pixel off the image gives a cell off the map.
    func cell(u: Double, v: Double) -> (column: Int, row: Int) {
        // A pixel centre at u lies in the cell whose span [c, c + 1) / scale holds u + 0.5.
        let column = ((u + 0.5) * scale.x).rounded(.down)
        let row = ((v + 0.5) * scale.y).rounded(.down)
        return (column.clampedInt, row.clampedInt)
    }

    /// The image pixel at the centre of a cell: the inverse of `cell(u:v:)`.
    func pixelCentre(column: Int, row: Int) -> (u: Double, v: Double) {
        ((Double(column) + 0.5) / scale.x - 0.5, (Double(row) + 0.5) / scale.y - 0.5)
    }

    /// A window of `columns` x `rows` cells centred on the cell under pixel (u, v).
    func window(centredOnU u: Double, v: Double, columns: Int, rows: Int) -> CellWindow {
        let centre = cell(u: u, v: v)
        return CellWindow(column: centre.column - columns / 2, row: centre.row - rows / 2,
                          columns: columns, rows: rows)
    }

    /// A window centred on pixel (u, v) big enough to cover `bounds` (image pixels), each side kept
    /// between `minCells` and its cap. A capped window keeps the middle of the bounds.
    func window(centredOnU u: Double, v: Double, covering bounds: CGRect,
                maxColumns: Int, maxRows: Int, minCells: Int) -> CellWindow {
        let columns = Self.cells(Double(bounds.width) * scale.x, min: minCells, max: maxColumns)
        let rows = Self.cells(Double(bounds.height) * scale.y, min: minCells, max: maxRows)
        return window(centredOnU: u, v: v, columns: columns, rows: rows)
    }

    private static func cells(_ span: Double, min lower: Int, max upper: Int) -> Int {
        guard span.isFinite else { return upper }
        return Swift.min(Swift.max(Int(span.rounded(.up)), lower), upper)
    }
}

extension Double {
    /// The value as an Int, pinned to a range far beyond any image so a wild value cannot trap.
    var clampedInt: Int {
        guard isFinite else { return self > 0 ? Self.intLimit : -Self.intLimit }
        return Int(Swift.min(Swift.max(self, Double(-Self.intLimit)), Double(Self.intLimit)))
    }

    private static let intLimit = 1 << 30
}
