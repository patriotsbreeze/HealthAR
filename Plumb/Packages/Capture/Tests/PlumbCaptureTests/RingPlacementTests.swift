import Foundation
import simd
import Testing
@testable import PlumbCapture

struct RingPlacementTests {
    /// A 9 x 9 grid of points 1 cm apart on the plane through `origin` square to `normal`, each
    /// lifted off it by `offsetM(column, row)`.
    func grid(normal: SIMD3<Double>, origin: SIMD3<Double> = SIMD3(0, 0, -1),
              offsetM: (Int, Int) -> Double = { _, _ in 0 }) -> [SIMD3<Double>] {
        let n = simd_normalize(normal)
        let across = simd_normalize(simd_cross(n, abs(n.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 0, 1)))
        let along = simd_cross(n, across)
        return (0..<81).map { index in
            let column = index % 9 - 4, row = index / 9 - 4
            return origin + across * (Double(column) * 0.01) + along * (Double(row) * 0.01) + n * offsetM(column, row)
        }
    }

    func ring(_ points: [SIMD3<Double>]) -> RingPlacement {
        RingPlacement.fitted(at: SIMD3(0, 0, -1), to: points, minPoints: 30, maxTiltRadians: 0.6, maxRoughnessM: 0.006)
    }

    @Test func aFlatSurfaceGivesItsNormalAndNoRoughness() throws {
        let leaning = SIMD3(0, cos(0.3), sin(0.3))
        let fit = try #require(SurfaceFit(grid(normal: leaning)))
        #expect(abs(abs(simd_dot(fit.normal, leaning)) - 1) < 1e-9)
        #expect(fit.roughnessM < 1e-9)
    }

    @Test func roughnessIsTheSpreadOffTheSurface() throws {
        // Every other point 2 mm above the surface and the rest 2 mm below.
        let fit = try #require(SurfaceFit(grid(normal: SIMD3(0, 1, 0)) { column, row in
            (column + row).isMultiple(of: 2) ? 0.002 : -0.002
        }))
        #expect(abs(fit.roughnessM - 0.002) < 1e-4)
        #expect(abs(fit.normal.y) > 0.999)
    }

    @Test func tooFewOrIdenticalPointsFitNothing() {
        #expect(SurfaceFit([SIMD3(0, 0, -1), SIMD3(0.1, 0, -1)]) == nil)
        #expect(SurfaceFit(Array(repeating: SIMD3(0, 0, -1), count: 10)) == nil)
    }

    @Test func aLeaningChestTiltsTheRing() {
        let leaning = SIMD3(0, cos(0.3), sin(0.3))
        let placed = ring(grid(normal: leaning))
        #expect(simd_distance(placed.normal, leaning) < 1e-9)
        #expect(placed.centre == SIMD3(0, 0, -1))
        #expect(simd_distance(placed.rotation.act(SIMD3<Float>(0, 1, 0)), SIMD3<Float>(leaning)) < 1e-6)
    }

    @Test func theRingFacesUpWhicheverWayTheFitPoints() {
        // Fitted from below, the normal would point down; the ring still faces up.
        let placed = ring(grid(normal: SIMD3(0, -cos(0.2), sin(0.2))))
        #expect(placed.normal.y > 0.97)
    }

    @Test func untrustworthySurfacesLeaveTheRingLevel() {
        let up = RingPlacement.up
        // A wall, too steep to be a chest lying down.
        #expect(ring(grid(normal: SIMD3(0, 0, 1))).normal == up)
        // A hand's edge on a chest: almost half the points 4 cm higher.
        #expect(ring(grid(normal: SIMD3(0, cos(0.3), sin(0.3))) { column, _ in column > 0 ? 0.04 : 0 }).normal == up)
        // Too few readings to trust.
        #expect(ring(Array(grid(normal: SIMD3(0, cos(0.3), sin(0.3))).prefix(20))).normal == up)
    }
}

struct RingShapeTests {
    let shape = RingShape(innerRadiusM: 0.0375, outerRadiusM: 0.0425, segments: 96)

    @Test func everyCornerIsOnOneOfTheTwoCircles() {
        #expect(shape.positions.count == 192)
        for (index, corner) in shape.positions.enumerated() {
            #expect(corner.y == 0)
            let radius = simd_length(corner)
            #expect(abs(radius - (index.isMultiple(of: 2) ? 0.0375 : 0.0425)) < 1e-6)
        }
    }

    @Test func trianglesCloseTheBandAndFaceUp() {
        #expect(shape.triangles.count == 96 * 6)
        #expect(shape.triangles.allSatisfy { $0 < 192 })
        for start in stride(from: 0, to: shape.triangles.count, by: 3) {
            let a = shape.positions[Int(shape.triangles[start])]
            let b = shape.positions[Int(shape.triangles[start + 1])]
            let c = shape.positions[Int(shape.triangles[start + 2])]
            #expect(simd_cross(b - a, c - a).y > 0)
        }
        // The last step joins back to the first corners.
        #expect(shape.triangles.suffix(6).contains(0) && shape.triangles.suffix(6).contains(1))
    }

    @Test func atLeastThreeStepsRound() {
        #expect(RingShape(innerRadiusM: 0.01, outerRadiusM: 0.02, segments: 1).positions.count == 6)
    }
}
