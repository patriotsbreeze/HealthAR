import Foundation
import PlumbContracts

/// Smooth, repeatable random brightness over a rectangle of a plane, so a surface that moves
/// carries its pattern with it and two surfaces with different seeds look nothing alike.
struct Texture {
    /// Size of one blob of the pattern, in the plane's own units.
    let cell: Double
    private let originX: Int
    private let originY: Int
    private let countX: Int
    private let countY: Int
    /// One random value per lattice corner, drawn once so lookups are cheap.
    private let lattice: [Double]

    /// A pattern defined over the given stretch of the plane; outside it the edge values repeat.
    init(seed: UInt64, cell: Double, x: ClosedRange<Double>, y: ClosedRange<Double>) {
        self.cell = cell
        originX = Int((x.lowerBound / cell).rounded(.down))
        originY = Int((y.lowerBound / cell).rounded(.down))
        countX = Int((x.upperBound / cell).rounded(.up)) - originX + 2
        countY = Int((y.upperBound / cell).rounded(.up)) - originY + 2
        var generator = SplitMix64(seed: seed)
        lattice = (0..<(countX * countY)).map { _ in generator.nextUnit() }
    }

    /// Brightness 0...1 at a point of the plane.
    func value(_ x: Double, _ y: Double) -> Double {
        let gx = min(max(x / cell - Double(originX), 0), Double(countX - 1))
        let gy = min(max(y / cell - Double(originY), 0), Double(countY - 1))
        let x0 = min(Int(gx), countX - 2)
        let y0 = min(Int(gy), countY - 2)
        let fx = Self.ease(gx - Double(x0))
        let fy = Self.ease(gy - Double(y0))
        let row = y0 * countX + x0
        let top = lattice[row] * (1 - fx) + lattice[row + 1] * fx
        let bottom = lattice[row + countX] * (1 - fx) + lattice[row + countX + 1] * fx
        return top * (1 - fy) + bottom * fy
    }

    private static func ease(_ t: Double) -> Double {
        t * t * (3 - 2 * t)
    }
}
