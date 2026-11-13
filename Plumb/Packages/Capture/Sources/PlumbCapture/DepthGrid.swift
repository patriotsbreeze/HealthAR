import CoreGraphics
import Foundation

/// A square of LiDAR depths read around one point of a scene snapshot, with what turns it into real
/// sizes: at a planar depth of d metres, p image pixels span p * d / `focalLengthPx` metres.
public struct DepthGrid: Sendable, Equatable {
    /// Planar depth of each cell in metres, row by row from the top-left; not-a-number where there
    /// is no confident reading.
    public let depthsM: [Double]
    /// Cells across.
    public let width: Int
    /// Cells down.
    public let height: Int
    /// The camera's focal length in image pixels, the mean of its two axes.
    public let focalLengthPx: Double
    /// Width the grid covers, in full-resolution image pixels.
    public let widthPx: Double
    /// Height the grid covers, in full-resolution image pixels.
    public let heightPx: Double

    /// Grids are equal when every field matches, a cell with no reading matching any other without one.
    public static func == (lhs: DepthGrid, rhs: DepthGrid) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height && lhs.focalLengthPx == rhs.focalLengthPx
            && lhs.widthPx == rhs.widthPx && lhs.heightPx == rhs.heightPx
            && lhs.depthsM.elementsEqual(rhs.depthsM) { $0 == $1 || ($0.isNaN && $1.isNaN) }
    }
}

extension SceneSnapshot {
    /// Reads a `cells` x `cells` grid of depths over a square `sidePx` full-resolution image pixels
    /// on a side, centred on a normalised image point. Each cell takes the depth-map cell under its
    /// centre. A cell off the picture, or whose reading is below `CaptureConfig.probeMinConfidence`
    /// as it was when the snapshot was taken, is not-a-number. Nil when the point is outside the
    /// picture, `sidePx` is not above zero or `cells` is below 1.
    public func depthGrid(around point: CGPoint, sidePx: Double, cells: Int) -> DepthGrid? {
        guard (0...1).contains(point.x), (0...1).contains(point.y), sidePx > 0, sidePx.isFinite, cells >= 1 else {
            return nil
        }
        let centre = pixel(at: point)
        let pitch = sidePx / Double(cells)
        let map = DepthCells(intrinsics: intrinsics, mapWidth: depth.width, mapHeight: depth.height)
        var depths: [Double] = []
        depths.reserveCapacity(cells * cells)
        for row in 0..<cells {
            let v = centre.v + (Double(row) + 0.5 - Double(cells) / 2) * pitch
            for column in 0..<cells {
                let u = centre.u + (Double(column) + 0.5 - Double(cells) / 2) * pitch
                let cell = map.cell(u: u, v: v)
                depths.append(depth.depthM(column: cell.column, row: cell.row, minConfidence: minConfidence) ?? .nan)
            }
        }
        return DepthGrid(depthsM: depths, width: cells, height: cells,
                         focalLengthPx: (intrinsics.fx + intrinsics.fy) / 2, widthPx: sidePx, heightPx: sidePx)
    }
}
