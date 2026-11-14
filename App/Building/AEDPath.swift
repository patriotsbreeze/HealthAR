import Foundation
import simd

/// The guide's arithmetic, apart from ARKit so it can be tested. A route lives in the entrance frame,
/// (right, forward) in metres from the doorway. The world is ARKit's, gravity-aligned: y is up.
enum AEDPath {
    static func length(_ points: [SIMD2<Double>]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
    }

    enum Turn: Equatable, Sendable {
        case left, right
    }

    struct Progress: Equatable, Sendable {
        /// From where the person is, onto the path, then along it to the end.
        var remaining: Double
        var turn: Turn?
        /// Along the path to that turn. Zero with no turn ahead.
        var toTurn: Double
    }

    /// A bend gentler than this is walked as straight on.
    static let straightAhead = sin(20.0 * .pi / 180)

    /// Where the person is, given in the entrance frame, against the route. Snaps to the closest point on
    /// the path, so a step off it adds that step and no more.
    static func progress(at position: SIMD2<Double>, along points: [SIMD2<Double>]) -> Progress {
        guard points.count >= 2 else {
            return Progress(remaining: points.first.map { simd_distance(position, $0) } ?? 0, turn: nil, toTurn: 0)
        }
        var best = (leg: 0, point: points[0], offset: Double.infinity)
        for leg in 0..<(points.count - 1) {
            let a = points[leg]
            let b = points[leg + 1]
            let ab = b - a
            let squared = simd_length_squared(ab)
            let t = squared > 0 ? min(max(simd_dot(position - a, ab) / squared, 0), 1) : 0
            let point = a + ab * t
            let offset = simd_distance(position, point)
            if offset < best.offset - 1e-9 { best = (leg, point, offset) }
        }
        // Along the path from the snapped point to each waypoint still ahead.
        var along = simd_distance(best.point, points[best.leg + 1])
        var turn: Turn?
        var toTurn = 0.0
        var corner = best.leg + 1
        while corner < points.count - 1 {
            if turn == nil, let bend = self.turn(from: points[corner - 1], at: points[corner], to: points[corner + 1]) {
                turn = bend
                toTurn = along
            }
            along += simd_distance(points[corner], points[corner + 1])
            corner += 1
        }
        return Progress(remaining: best.offset + along, turn: turn, toTurn: toTurn)
    }

    /// Left or right at a corner, by the sign of the cross product of the legs either side. In
    /// (right, forward) a positive cross is a turn to the left. Nil when it's near enough straight.
    static func turn(from a: SIMD2<Double>, at b: SIMD2<Double>, to c: SIMD2<Double>) -> Turn? {
        let first = b - a
        let second = c - b
        let lengths = simd_length(first) * simd_length(second)
        guard lengths > 0 else { return nil }
        let cross = (first.x * second.y - first.y * second.x) / lengths
        if abs(cross) < straightAhead { return nil }
        return cross > 0 ? .left : .right
    }

    /// Where a point lands on the route: metres along it from the start, and how far off it.
    static func snap(_ position: SIMD2<Double>, onto points: [SIMD2<Double>]) -> (along: Double, offset: Double) {
        guard points.count >= 2 else { return (0, points.first.map { simd_distance(position, $0) } ?? 0) }
        var best = (along: 0.0, offset: Double.infinity)
        var before = 0.0
        for leg in 0..<(points.count - 1) {
            let a = points[leg]
            let ab = points[leg + 1] - a
            let squared = simd_length_squared(ab)
            let t = squared > 0 ? min(max(simd_dot(position - a, ab) / squared, 0), 1) : 0
            let offset = simd_distance(position, a + ab * t)
            if offset < best.offset - 1e-9 { best = (before + simd_length(ab) * t, offset) }
            before += simd_length(ab)
        }
        return best
    }

    /// A step counts as passed once the person is within this of the point where its leg ends.
    static let stepReached = 1.5

    /// The step to show: the first whose end the person hasn't reached, or the last once they all are.
    /// Measured along the route, so walking past a point a little to one side still passes it.
    static func currentStep(at position: SIMD2<Double>, along points: [SIMD2<Double>], steps: [BuildingBrief.Route.Step]) -> Int? {
        guard !steps.isEmpty else { return nil }
        let here = snap(position, onto: points)
        for (index, step) in steps.enumerated() {
            let end = snap(step.at, onto: points).along
            let passed = here.along >= end - stepReached || simd_distance(position, step.at) <= stepReached
            if !passed { return index }
        }
        return steps.count - 1
    }

    /// A recorded walk keeps only the corners further than this from the straight line between its neighbours.
    static let markTolerance = 0.75

    /// Ramer–Douglas–Peucker: the fewest points that stay within `tolerance` of the walk.
    static func simplify(_ points: [SIMD2<Double>], tolerance: Double) -> [SIMD2<Double>] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        var farthest = (index: 0, distance: 0.0)
        for index in 1..<(points.count - 1) {
            let distance = distanceToSegment(points[index], first, last)
            if distance > farthest.distance { farthest = (index, distance) }
        }
        guard farthest.distance > tolerance else { return [first, last] }
        let before = simplify(Array(points[...farthest.index]), tolerance: tolerance)
        let after = simplify(Array(points[farthest.index...]), tolerance: tolerance)
        return before.dropLast() + after
    }

    static func distanceToSegment(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a
        let squared = simd_length_squared(ab)
        let t = squared > 0 ? min(max(simd_dot(p - a, ab) / squared, 0), 1) : 0
        return simd_distance(p, a + ab * t)
    }

    /// The point this far along the route, held to its ends. For the preview's pretend walk.
    static func point(at distance: Double, along points: [SIMD2<Double>]) -> SIMD2<Double> {
        guard var last = points.first else { return .zero }
        var left = max(distance, 0)
        for next in points.dropFirst() {
            let leg = simd_distance(last, next)
            if left <= leg, leg > 0 { return last + (next - last) * (left / leg) }
            left -= leg
            last = next
        }
        return last
    }
}

/// The entrance frame in the world, fixed by one tap in the doorway: where the person stands, on the
/// floor, which way is into the building, and which way is their right.
struct EntranceFrame: Equatable, Sendable {
    var origin: SIMD3<Float>
    /// Unit length and level.
    var forward: SIMD3<Float>
    var right: SIMD3<Float>

    /// How far below the camera the floor is taken to be when no floor has been found.
    static let eyeHeight: Float = 1.4
    /// The level part of the camera's view direction must be at least this, about 78° from straight
    /// down or up, or there's no telling which way the phone faces.
    static let leastLevel: Float = 0.2

    /// From the camera's pose at the tap. The camera looks down its -Z. Nil when the phone is flat.
    static func calibrate(camera: simd_float4x4, floorY: Float?) -> EntranceFrame? {
        let position = SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let look = -SIMD3(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
        let level = SIMD3(look.x, 0, look.z)
        let size = simd_length(level)
        guard size >= leastLevel else { return nil }
        let forward = level / size
        let right = simd_cross(forward, SIMD3(0, 1, 0))
        let floor = floorY ?? position.y - eyeHeight
        return EntranceFrame(origin: SIMD3(position.x, floor, position.z), forward: forward, right: right)
    }

    /// A waypoint on the floor.
    func world(_ waypoint: SIMD2<Double>) -> SIMD3<Float> {
        origin + right * Float(waypoint.x) + forward * Float(waypoint.y)
    }

    /// A world position in the entrance frame, height dropped.
    func local(_ position: SIMD3<Float>) -> SIMD2<Double> {
        let offset = position - origin
        return SIMD2(Double(simd_dot(offset, right)), Double(simd_dot(offset, forward)))
    }
}

/// The compass arrow on the calibrate screen. Degrees clockwise from true north.
enum Compass {
    /// Within this either side of the first leg's bearing, the person counts as facing the right way.
    static let tolerance = 12.0

    /// Into [0, 360).
    static func normalized(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    /// How far to turn the arrow so it points along the bearing, from where the phone faces: bearing
    /// minus heading, into (-180, 180]. Bearing 7, heading 350 gives 17, a small turn right.
    static func rotation(bearing: Double, heading: Double) -> Double {
        let turn = normalized(bearing - heading)
        return turn > 180 ? turn - 360 : turn
    }

    static func isFacing(bearing: Double, heading: Double) -> Bool {
        abs(rotation(bearing: bearing, heading: heading)) <= tolerance
    }

    /// True north when the phone knows it, else magnetic. Nil when it has neither.
    static func heading(true trueHeading: Double, magnetic: Double) -> Double? {
        if trueHeading >= 0 { return trueHeading }
        return magnetic >= 0 ? magnetic : nil
    }
}
