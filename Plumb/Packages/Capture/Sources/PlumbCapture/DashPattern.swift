import Foundation

/// How a bar of a given length is cut into dashes: as many whole dashes as fit with a gap between
/// each, centred, so the pattern is the same at both ends.
enum DashPattern {
    /// One piece of the bar: where its middle is, measured from the middle of the bar, and its length.
    struct Piece: Sendable, Equatable {
        var centre: Double
        var length: Double
    }

    /// The bar whole, as one piece.
    static func solid(lengthM: Double) -> [Piece] {
        [Piece(centre: 0, length: lengthM)]
    }

    /// The dashes of a bar `lengthM` long cut into dashes `dashM` long with `gapM` between them.
    /// A bar too short for two dashes stays one piece; nothing is drawn for a bar of no length.
    static func dashed(lengthM: Double, dashM: Double, gapM: Double) -> [Piece] {
        guard lengthM > 0 else { return [] }
        guard dashM > 0, gapM >= 0 else { return solid(lengthM: lengthM) }
        let count = Int(((lengthM + gapM) / (dashM + gapM)).rounded(.down))
        guard count >= 2 else { return solid(lengthM: lengthM) }
        let spanM = Double(count) * dashM + Double(count - 1) * gapM
        return (0..<count).map { index in
            Piece(centre: -spanM / 2 + dashM / 2 + Double(index) * (dashM + gapM), length: dashM)
        }
    }
}
