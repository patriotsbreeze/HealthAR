import Foundation
import PlumbContracts
import PlumbGeometry
import simd

extension FramePipeline {
    /// The ring at `centre`, lying on the surface this frame's depth map shows around it.
    func placeRing(around centre: SIMD3<Double>, depth: DepthMap, camera: FrameCamera) -> RingPlacement {
        RingPlacement.fitted(at: centre, to: surfacePoints(around: centre, depth: depth, camera: camera),
                             minPoints: config.ringFitMinPoints, maxTiltRadians: config.ringMaxTiltRadians,
                             maxRoughnessM: config.ringMaxRoughnessM)
    }

    /// The world points the depth map reads within `ringFitRadiusM` of `centre`: every confident
    /// cell of a window sized to hold that radius, put in the world and kept when it lands near
    /// enough. Empty when the centre is behind the camera.
    func surfacePoints(around centre: SIMD3<Double>, depth: DepthMap, camera: FrameCamera) -> [SIMD3<Double>] {
        let radiusM = config.ringFitRadiusM
        let box = WorldBox(centre: centre, widthM: 2 * radiusM, heightM: 2 * radiusM)
        guard let seen = Projection.project(centre, intrinsics: camera.intrinsics, pose: camera.pose),
              let bounds = box.imageBounds(intrinsics: camera.intrinsics, pose: camera.pose) else { return [] }
        let cells = DepthCells(intrinsics: camera.intrinsics, mapWidth: depth.width, mapHeight: depth.height)
        let window = cells.window(centredOnU: seen.u, v: seen.v, covering: bounds, maxColumns: config.ringFitMaxCells,
                                  maxRows: config.ringFitMaxCells, minCells: config.minPatchCells)
        var points: [SIMD3<Double>] = []
        for row in window.row..<(window.row + window.rows) {
            for column in window.column..<(window.column + window.columns) {
                guard let depthM = depth.depthM(column: column, row: row, minConfidence: config.probeMinConfidence) else {
                    continue
                }
                let pixel = cells.pixelCentre(column: column, row: row)
                let point = Projection.unproject(u: pixel.u, v: pixel.v, depthM: depthM,
                                                 intrinsics: camera.intrinsics, pose: camera.pose)
                if simd_distance(point, centre) <= radiusM { points.append(point) }
            }
        }
        return points
    }

    /// The world height of the top of the hands this frame: where the line of sight through the
    /// hands box centre meets the nearest surface in the hands patch, as the along-ray method reads
    /// it. Nil when the frame gave no valid sample or the patch shows no surface.
    func topOfHandsM(_ traced: TraceFrame, sample: HeightSample?) -> Double? {
        guard let sample, sample.quality >= config.validQuality,
              let reading = traced.hands?.nearestSurface(minConfidence: config.estimator.minConfidence,
                                                         config: config.estimator.surface) else { return nil }
        return Projection.unproject(u: traced.handsU, v: traced.handsV, depthM: reading.depthM,
                                    intrinsics: traced.intrinsics, pose: traced.pose).y
    }

    /// Where the ring and the target line stand after this frame. The line needs the top of the
    /// stroke and a camera pose that means something (`tracked`); its target is the adult minimum
    /// depth below that top.
    func guides(camera: FrameCamera, tracked: Bool) -> GuidePlacement {
        guard let hands else { return .none }
        let line = restTop.topM.flatMap { topM in
            tracked ? LinePlacement.place(handsCentre: hands.centre, restTopM: topM,
                                          sinkM: Targets.adult.depthMinMM / 1000, pose: camera.pose,
                                          towardCameraM: config.lineTowardCameraM,
                                          maxSlideM: config.lineMaxSlideM) : nil
        }
        return GuidePlacement(ring: ring, line: line)
    }
}
