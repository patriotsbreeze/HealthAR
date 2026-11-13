import Foundation
import simd

/// Where each sample of a luma patch sits in the image, so the code that reads the camera's
/// brightness plane and the estimator agree on the layout.
///
/// Rows run across the direction world-up takes in the image. Row 0 is the highest in the world;
/// column 0 is on the left for an upright camera.
public struct LumaGrid: Sendable, Equatable {
    /// The u coordinate of the grid's centre, in image pixels.
    public var centreU: Double
    /// The v coordinate of the grid's centre, in image pixels.
    public var centreV: Double
    /// Unit image direction a move straight up in the world takes at the centre.
    public var upDirection: SIMD2<Double>
    /// Samples per row.
    public var columns: Int
    /// Number of rows.
    public var rows: Int
    /// Distance between neighbouring rows, in image pixels.
    public var pitchPx: Double
    /// Distance between neighbouring samples within a row, in image pixels.
    public var columnPitchPx: Double

    /// Builds a grid from its centre, its up direction and its spacing.
    public init(centreU: Double, centreV: Double, upDirection: SIMD2<Double>, columns: Int, rows: Int,
                pitchPx: Double, columnPitchPx: Double) {
        self.centreU = centreU
        self.centreV = centreV
        self.upDirection = upDirection
        self.columns = columns
        self.rows = rows
        self.pitchPx = pitchPx
        self.columnPitchPx = columnPitchPx
    }

    /// A grid centred on pixel (u, v) that covers `heightM` of world height and `widthM` across,
    /// for a surface `depthM` metres along the lens axis. Nil when the camera looks straight
    /// along the vertical there, where "up" has no direction in the image.
    public static func spanning(heightM: Double, widthM: Double, columns: Int, rows: Int,
                                u: Double, v: Double, depthM: Double,
                                intrinsics: Intrinsics, pose: CameraPose) -> LumaGrid? {
        guard columns > 0, rows > 0 else { return nil }
        let centre = Projection.unproject(u: u, v: v, depthM: depthM, intrinsics: intrinsics, pose: pose)
        // Level in the world and square to the lens axis: the way "across" runs on a surface facing the camera.
        let sideways = simd_cross(SIMD3(0, 1, 0), pose.rotation.columns.2)
        guard simd_length(sideways) > 0,
              let up = Projection.pixelsPerMetreAlongUp(at: centre, intrinsics: intrinsics, pose: pose),
              let across = Projection.imageMotion(at: centre, along: simd_normalize(sideways),
                                                  intrinsics: intrinsics, pose: pose) else { return nil }
        return LumaGrid(centreU: u, centreV: v, upDirection: up.direction, columns: columns, rows: rows,
                        pitchPx: heightM * up.pixels / Double(rows),
                        columnPitchPx: widthM * simd_length(across) / Double(columns))
    }

    /// The image position, as (u, v), of one sample.
    public func imagePoint(column: Int, row: Int) -> SIMD2<Double> {
        // A quarter turn of "up" that points right in the image when the camera is upright.
        let acrossDirection = SIMD2(-upDirection.y, upDirection.x)
        let down = (Double(row) - Double(rows - 1) / 2) * pitchPx
        let along = (Double(column) - Double(columns - 1) / 2) * columnPitchPx
        return SIMD2(centreU, centreV) - upDirection * down + acrossDirection * along
    }

    /// Builds the patch by asking `brightness` for the value at each sample's image position.
    public func sample(_ brightness: (_ u: Double, _ v: Double) -> UInt8) -> LumaPatch {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let point = imagePoint(column: column, row: row)
                pixels.append(brightness(point.x, point.y))
            }
        }
        return LumaPatch(width: columns, height: rows, pitchPx: pitchPx, pixels: pixels)
    }
}
