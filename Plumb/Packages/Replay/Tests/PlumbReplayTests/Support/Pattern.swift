import Foundation
import PlumbContracts

/// Smooth, repeatable random brightness over a rectangle of a level surface, so a surface that
/// moves carries its pattern with it. Outside the rectangle the edge values carry on.
struct Pattern {
    let cell: Double
    private let halfCells: SIMD2<Int>
    private let columns: Int
    private let rows: Int
    /// One random value per lattice corner, drawn once so lookups are cheap.
    private let lattice: [Double]

    /// A pattern over the rectangle from -halfSize to +halfSize, in blobs about `cell` across.
    init(seed: UInt64, cell: Double, halfSize: SIMD2<Double>) {
        self.cell = cell
        halfCells = SIMD2(Int((halfSize.x / cell).rounded(.up)), Int((halfSize.y / cell).rounded(.up)))
        columns = 2 * halfCells.x + 2
        rows = 2 * halfCells.y + 2
        var generator = SplitMix64(seed: seed)
        lattice = (0..<(columns * rows)).map { _ in generator.nextUnit() }
    }

    /// Brightness 0...1 at a point of the surface, measured from the rectangle's middle.
    func value(at point: SIMD2<Double>) -> Double {
        let gx = min(max(point.x / cell + Double(halfCells.x), 0), Double(columns - 1))
        let gy = min(max(point.y / cell + Double(halfCells.y), 0), Double(rows - 1))
        let x0 = min(Int(gx), columns - 2)
        let y0 = min(Int(gy), rows - 2)
        let fx = Self.ease(gx - Double(x0))
        let fy = Self.ease(gy - Double(y0))
        let corner = y0 * columns + x0
        let near = lattice[corner] * (1 - fx) + lattice[corner + 1] * fx
        let far = lattice[corner + columns] * (1 - fx) + lattice[corner + columns + 1] * fx
        return near * (1 - fy) + far * fy
    }

    private static func ease(_ t: Double) -> Double {
        t * t * (3 - 2 * t)
    }
}
