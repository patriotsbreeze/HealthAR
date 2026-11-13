import Foundation
import PlumbGeometry
import simd

/// The fixed rules that turn the people Vision found into the world point the hands press on.
enum HandsFinder {
    /// The hands of the nearest person who looks like they are doing compressions, as a world
    /// point, or nil when no one does. See `candidate` for the rules each person must pass.
    static func find(_ bodies: [BodyJoints], depth: DepthMap, camera: FrameCamera,
                     config: CaptureConfig) -> SIMD3<Double>? {
        let candidates = bodies.compactMap { candidate($0, depth: depth, camera: camera, config: config) }
        guard let chosen = nearest(candidates.map(\.rangeM), within: config.bystanderRangeM) else { return nil }
        return candidates[chosen].hands
    }

    /// One person who passed the posture rules: how far away their wrists read, and their hands.
    struct Candidate: Sendable, Equatable {
        /// The farther of the two wrists' depths, in metres.
        var rangeM: Double
        /// Where their hands are, in the world.
        var hands: SIMD3<Double>
    }

    /// Applies the rules to one person: both wrists read in the depth map, within `wristsTogetherM`
    /// of each other in the world, and below the shoulders. The hands are then placed by
    /// `handsPixel` and put at the nearest surface found there. Nil when any rule fails.
    static func candidate(_ body: BodyJoints, depth: DepthMap, camera: FrameCamera,
                          config: CaptureConfig) -> Candidate? {
        guard let left = body.leftWrist, let right = body.rightWrist else { return nil }
        let cells = DepthCells(intrinsics: camera.intrinsics, mapWidth: depth.width, mapHeight: depth.height)
        func depthAt(_ pixel: SIMD2<Double>) -> Double? {
            let window = cells.window(centredOnU: pixel.x, v: pixel.y, columns: config.probeCells, rows: config.probeCells)
            return depth.medianDepth(in: window, minConfidence: config.probeMinConfidence)
        }
        func world(_ pixel: SIMD2<Double>, _ depthM: Double) -> SIMD3<Double> {
            Projection.unproject(u: pixel.x, v: pixel.y, depthM: depthM,
                                 intrinsics: camera.intrinsics, pose: camera.pose)
        }
        guard let leftDepth = depthAt(left), let rightDepth = depthAt(right) else { return nil }
        let leftWorld = world(left, leftDepth), rightWorld = world(right, rightDepth)
        guard simd_distance(leftWorld, rightWorld) <= config.wristsTogetherM,
              let up = Projection.pixelsPerMetreAlongUp(at: (leftWorld + rightWorld) / 2,
                                                        intrinsics: camera.intrinsics, pose: camera.pose),
              wristsBelowShoulders(body, upDirection: up.direction),
              let hands = handsPixel(body, beyondWristShare: config.handsBeyondWristShare) else { return nil }
        // The nearest surface, not the median: the hands are in front of the chest they press on.
        let window = cells.window(centredOnU: hands.x, v: hands.y, columns: config.probeCells, rows: config.probeCells)
        guard let reading = depth.cut(window).nearestSurface(minConfidence: config.probeMinConfidence,
                                                             config: config.estimator.surface) else { return nil }
        return Candidate(rangeM: max(leftDepth, rightDepth), hands: world(hands, reading.depthM))
    }

    /// Where the hands sit in the image: the midpoint of the wrists, carried on past them along
    /// the forearms (elbow to wrist) by `share` of the forearm's length. With no elbow found the
    /// midpoint itself. Nil without both wrists.
    static func handsPixel(_ body: BodyJoints, beyondWristShare share: Double) -> SIMD2<Double>? {
        guard let left = body.leftWrist, let right = body.rightWrist else { return nil }
        let middle = (left + right) / 2
        let forearms = [body.leftElbow.map { left - $0 }, body.rightElbow.map { right - $0 }].compactMap { $0 }
        guard !forearms.isEmpty else { return middle }
        let forearm = forearms.reduce(SIMD2<Double>.zero, +) / Double(forearms.count)
        return middle + forearm * share
    }

    /// True when both wrists are lower in the world than the shoulders, judged along `upDirection`,
    /// the image direction world-up takes at the wrists. False without both wrists and a shoulder.
    static func wristsBelowShoulders(_ body: BodyJoints, upDirection: SIMD2<Double>) -> Bool {
        let shoulders = [body.leftShoulder, body.rightShoulder].compactMap { $0 }
        guard let left = body.leftWrist, let right = body.rightWrist, !shoulders.isEmpty else { return false }
        let shoulder = shoulders.reduce(SIMD2<Double>.zero, +) / Double(shoulders.count)
        return [left, right].allSatisfy { simd_dot(shoulder - $0, upDirection) > 0 }
    }

    /// Index of the nearest of the given ranges that is no farther than `maxRangeM`; anyone
    /// beyond it is a bystander. Nil when no one is near enough.
    static func nearest(_ rangesM: [Double], within maxRangeM: Double) -> Int? {
        rangesM.indices.filter { rangesM[$0] <= maxRangeM }.min { rangesM[$0] < rangesM[$1] }
    }
}
