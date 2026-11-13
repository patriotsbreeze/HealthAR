import Foundation
import PlumbContracts
@testable import PlumbAgents

/// A box standing off a wall, described in metres.
struct Box {
    var width: Double
    var height: Double
    /// How far its front face stands in front of the wall.
    var proud: Double
}

/// Builds the depth grid a sensor would see looking at a wall, with or without a box on it.
enum Wall {
    /// - Parameters:
    ///   - distance: depth of the wall where the camera's axis meets it, in metres.
    ///   - slant: how fast the wall recedes to the right, in metres of depth per metre across. 0 is face-on.
    ///   - box: an object centred on the proposed point, or nil for a bare wall.
    ///   - span: how much of the wall the grid covers at `distance`, in metres.
    ///   - noise: standard deviation of the sensor noise, in metres.
    static func probe(distance: Double, slant: Double = 0, box: Box? = nil, span: Double = 1.0, grid: Int = 32,
                      focal: Double = 1500, noise: Double = 0, seed: UInt64 = 7) -> SceneProbe {
        var random = SplitMix64(seed: seed)
        let patch = span * focal / distance
        var depths: [Double] = []
        for row in 0..<grid {
            for column in 0..<grid {
                // The ray through the middle of this cell.
                let tx = ((Double(column) + 0.5) / Double(grid) - 0.5) * patch / focal
                let ty = ((Double(row) + 0.5) / Double(grid) - 0.5) * patch / focal
                var depth = distance / (1 - slant * tx)
                if let box {
                    let face = (distance - box.proud) / (1 - slant * tx)
                    if abs(tx * face) <= box.width / 2, abs(ty * face) <= box.height / 2 {
                        depth = face
                    }
                }
                depths.append(depth + noise * random.nextGaussian())
            }
        }
        return SceneProbe(depthsM: depths, gridWidth: grid, gridHeight: grid, focalLengthPx: focal,
                          patchWidthPx: patch, patchHeightPx: patch)
    }

    /// A defibrillator-sized case: 30 cm wide, 25 cm tall, standing 8 cm off a wall 2 m away.
    static let caseOnWall = probe(distance: 2, box: Box(width: 0.3, height: 0.25, proud: 0.08))

    /// A bare wall 2 m away with 5 mm of sensor noise: what a poster or a sign looks like.
    static let poster = probe(distance: 2, noise: 0.005)
}

/// Builds the depth grid a sensor would see for any scene, given the depth at each place in it.
enum Patch {
    /// - Parameters:
    ///   - grid: cells along each side.
    ///   - span: how much of the scene the grid covers at `distance`, in metres.
    ///   - noise: standard deviation of the sensor noise, in metres.
    ///   - depth: the depth in metres at a place `x` metres right of and `y` metres below the
    ///     proposed point, both measured across the scene at `distance`.
    static func probe(grid: Int = 32, span: Double = 1.0, distance: Double = 2.0, focal: Double = 1500,
                      noise: Double = 0, seed: UInt64 = 11,
                      depth: (_ x: Double, _ y: Double) -> Double) -> SceneProbe {
        var random = SplitMix64(seed: seed)
        let patch = span * focal / distance
        var depths: [Double] = []
        for row in 0..<grid {
            for column in 0..<grid {
                let x = ((Double(column) + 0.5) / Double(grid) - 0.5) * span
                let y = ((Double(row) + 0.5) / Double(grid) - 0.5) * span
                depths.append(depth(x, y) + noise * random.nextGaussian())
            }
        }
        return SceneProbe(depthsM: depths, gridWidth: grid, gridHeight: grid, focalLengthPx: focal,
                          patchWidthPx: patch, patchHeightPx: patch)
    }

    /// A flat surface 2 m away on the camera's axis. `tiltX` and `tiltY` say how fast it comes
    /// nearer to the right and downwards; a floor seen from a propped phone has a large `tiltY`.
    static func plane(tiltX: Double = 0, tiltY: Double = 0) -> (Double, Double) -> Double {
        { x, y in 2.0 / (1 + tiltX * x / 2 + tiltY * y / 2) }
    }

    /// A box on that surface, centred `offsetX` and `offsetY` metres from the proposed point.
    static func box(_ box: Box, offsetX: Double = 0, offsetY: Double = 0, tiltX: Double = 0,
                    tiltY: Double = 0) -> (Double, Double) -> Double {
        let surface = plane(tiltX: tiltX, tiltY: tiltY)
        return { x, y in
            let inside = abs(x - offsetX) <= box.width / 2 && abs(y - offsetY) <= box.height / 2
            return surface(x, y) - (inside ? box.proud : 0)
        }
    }
}
