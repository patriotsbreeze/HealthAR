import CoreGraphics
import Foundation
import simd
import Testing
@testable import PlumbCapture

struct EdgePointerTests {
    /// A 1000 x 600 view; the edge the chevron sits on is 20 points in from it.
    let view = CGRect(x: 0, y: 0, width: 1000, height: 600)
    var edge: CGRect { view.insetBy(dx: 20, dy: 20) }
    /// A camera at the origin looking along world -z, upright.
    let camera = SIMD3<Float>(0, 0, 0)
    let forward = SIMD3<Float>(0, 0, -1)

    /// A pinhole like ARView's: 500 points per unit of sideways over distance, centred in the view.
    func project(_ point: SIMD3<Float>) -> CGPoint? {
        guard point.z < 0 else { return nil }
        return CGPoint(x: 500 + 500 * CGFloat(point.x / -point.z), y: 300 - 500 * CGFloat(point.y / -point.z))
    }

    func place(_ foot: SIMD3<Float>) -> EdgePointer.Placement? {
        EdgePointer.place(toward: foot, marks: AEDMarker.marks(standingAt: foot), camera: camera, forward: forward,
                          view: view, edge: edge, project: project)
    }

    @Test func noPointerWhileTheMarkerIsInSight() {
        #expect(place(SIMD3(0.5, -0.5, -3)) == nil)
        // The foot below the picture but the disc in it still counts as in sight.
        #expect(place(SIMD3(0, -1.4, -2)) == nil)
    }

    @Test func aMarkerOffToTheRightIsPointedAtFromTheRightEdge() throws {
        let pointer = try #require(place(SIMD3(4, -0.2, -2)))
        #expect(abs(pointer.position.x - edge.maxX) < 1e-9)
        #expect(abs(pointer.angle) < 0.1)
        #expect(edge.minY...edge.maxY ~= pointer.position.y)
    }

    @Test func aMarkerBehindAndToTheLeftIsPointedAtFromTheLeftEdge() throws {
        let pointer = try #require(place(SIMD3(-2, 0, 3)))
        #expect(abs(pointer.position.x - edge.minX) < 1e-9 && abs(pointer.position.y - edge.midY) < 1e-9)
        #expect(abs(abs(pointer.angle) - .pi) < 1e-9)
    }

    @Test func aMarkerDeadBehindIsPointedAtFromTheBottom() throws {
        let pointer = try #require(place(SIMD3(0, 0, 4)))
        #expect(pointer.position == CGPoint(x: edge.midX, y: edge.maxY))
        #expect(abs(pointer.angle - .pi / 2) < 1e-9)
    }

    @Test func mirroringKeepsTheSidewaysAndUpOffsets() {
        let mirrored = EdgePointer.inFront(SIMD3(1, 2, 3), camera: camera, forward: forward)
        #expect(mirrored == SIMD3(1, 2, -3))
        #expect(EdgePointer.inFront(SIMD3(1, 2, -3), camera: camera, forward: forward) == SIMD3(1, 2, -3))
        // Level with the lens: put just in front so it projects, far out to the side.
        #expect(EdgePointer.inFront(SIMD3(1, 0, 0), camera: camera, forward: forward).z < 0)
    }

    @Test func theChevronSitsWhereTheLineFromTheMiddleLeavesTheEdge() {
        // Up and to the right, steeper than the corner: it leaves through the top.
        let steep = EdgePointer.onEdge(toward: CGPoint(x: 600, y: -1000), of: edge)
        #expect(abs(steep.position.y - edge.minY) < 1e-9)
        #expect(abs(steep.position.x - (500 + 100 * 280 / 1300)) < 1e-9)
        // Shallow: it leaves through the right side, at the same slope.
        let shallow = EdgePointer.onEdge(toward: CGPoint(x: 5000, y: 400), of: edge)
        #expect(abs(shallow.position.x - edge.maxX) < 1e-9)
        #expect(abs(shallow.position.y - (300 + 100 * 480 / 4500)) < 1e-9)
    }

    @Test func theWordsSayTheDistanceInMetres() {
        #expect(EdgePointer.words(distanceM: 4.24) == "AED 4.2 m")
        #expect(EdgePointer.words(distanceM: 0.5) == "AED 0.5 m")
        #expect(EdgePointer.words(distanceM: 9.96) == "AED 10 m")
        #expect(EdgePointer.words(distanceM: 12.4) == "AED 12 m")
    }

    @Test func theWordsSitInsideBesideTheChevron() {
        let size = CGSize(width: 100, height: 30)
        let right = EdgePointer.Placement(position: CGPoint(x: 980, y: 300), angle: 0)
        let besideRight = EdgePointer.wordsFrame(size: size, beside: right, clearance: 14, within: view)
        #expect(besideRight == CGRect(x: 866, y: 285, width: 100, height: 30))
        let up = EdgePointer.Placement(position: CGPoint(x: 500, y: 20), angle: -.pi / 2)
        let underUp = EdgePointer.wordsFrame(size: size, beside: up, clearance: 14, within: view)
        #expect(underUp == CGRect(x: 450, y: 34, width: 100, height: 30))
        // In a corner the words are pushed back inside the view.
        let corner = EdgePointer.Placement(position: CGPoint(x: 5, y: 590), angle: .pi / 2)
        let kept = EdgePointer.wordsFrame(size: size, beside: corner, clearance: 14, within: view)
        #expect(view.contains(kept))
    }
}
