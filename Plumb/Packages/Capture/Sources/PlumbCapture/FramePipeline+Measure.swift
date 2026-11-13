import CoreVideo
import Foundation
import PlumbGeometry

extension FramePipeline {
    /// Builds the trace frame for the hands box: its depth patch, its brightness grid and the
    /// reference patch. Nil when the box is behind the camera.
    func measure(_ hands: HandsRegion, camera: FrameCamera, depth: DepthMap?, image: CVPixelBuffer,
                 t: TimeInterval, trackingNormal: Bool) -> TraceFrame? {
        guard let centre = Projection.project(hands.centre, intrinsics: camera.intrinsics, pose: camera.pose) else {
            return nil
        }
        let box = WorldBox(centre: hands.centre, widthM: config.handsWidthM, heightM: config.handsHeightM)
        let handsPatch = depth.flatMap {
            patch(of: box, in: $0, camera: camera, maxColumns: config.handsMaxColumns, maxRows: config.handsMaxRows)
        }
        let luma = lumaPatch(centredOn: centre, image: image, camera: camera)
        if reference == nil, trackingNormal, let depth {
            watchForReference(beside: hands.centre, depth: depth, camera: camera, t: t)
        }
        let still = reference.flatMap { referencePatch(at: $0, depth: depth, camera: camera) }
        return TraceFrame(t: t, intrinsics: camera.intrinsics, pose: camera.pose, trackingNormal: trackingNormal,
                          handsU: centre.u, handsV: centre.v, hands: handsPatch, handsLuma: luma?.patch,
                          handsLumaU: luma?.grid.centreU, handsLumaV: luma?.grid.centreV,
                          referenceU: still?.u, referenceV: still?.v, reference: still?.patch)
    }

    /// The depth cells under a world box, centred where its centre is seen and sized to hold it,
    /// within the given caps. Nil when the box is not wholly in front of the camera.
    func patch(of box: WorldBox, in depth: DepthMap, camera: FrameCamera,
               maxColumns: Int, maxRows: Int) -> DepthPatch? {
        guard let seen = Projection.project(box.centre, intrinsics: camera.intrinsics, pose: camera.pose),
              let bounds = box.imageBounds(intrinsics: camera.intrinsics, pose: camera.pose) else { return nil }
        let cells = DepthCells(intrinsics: camera.intrinsics, mapWidth: depth.width, mapHeight: depth.height)
        let window = cells.window(centredOnU: seen.u, v: seen.v, covering: bounds,
                                  maxColumns: maxColumns, maxRows: maxRows, minCells: config.minPatchCells)
        return depth.cut(window)
    }

    /// Reads the brightness grid over the hands. The grid is laid once per seed, square to world-up
    /// at the hands, and keeps that spacing and direction for good: the image-plane estimator only
    /// compares patches from a grid that never changes size. Its centre follows the box.
    private func lumaPatch(centredOn centre: (u: Double, v: Double, depthM: Double), image: CVPixelBuffer,
                           camera: FrameCamera) -> (patch: LumaPatch, grid: LumaGrid)? {
        if lumaGrid == nil {
            lumaGrid = LumaGrid.spanning(heightM: config.handsHeightM, widthM: config.handsWidthM,
                                         columns: config.lumaColumns, rows: config.lumaRows,
                                         u: centre.u, v: centre.v, depthM: centre.depthM,
                                         intrinsics: camera.intrinsics, pose: camera.pose)
        }
        guard var grid = lumaGrid else { return nil }
        grid.centreU = centre.u
        grid.centreV = centre.v
        lumaGrid = grid
        return LumaSampler.sample(grid, from: image).map { ($0, grid) }
    }

    /// Feeds one frame to the watch over the two candidate reference points, and fixes the
    /// reference once the watch decides.
    private func watchForReference(beside centre: SIMD3<Double>, depth: DepthMap, camera: FrameCamera,
                                   t: TimeInterval) {
        guard var watch = trial ?? ReferenceTrial(beside: centre, offsetM: config.referenceOffsetM,
                                                  pose: camera.pose) else { return }
        for (index, point) in watch.candidates.enumerated() {
            let reading = referencePatch(at: point, depth: depth, camera: camera)?.patch?
                .nearestSurface(minConfidence: config.estimator.minConfidence, config: config.estimator.surface)
            watch.observe(reading?.depthM, candidate: index, at: t)
        }
        reference = watch.decide(at: t, durationS: config.referenceTrialS,
                                 minReadings: config.referenceTrialMinReadings)
        trial = reference == nil ? watch : nil
    }

    /// Where a reference point is seen and the depth patch around it. Nil when it is behind the camera.
    private func referencePatch(at point: SIMD3<Double>, depth: DepthMap?,
                                camera: FrameCamera) -> (u: Double, v: Double, patch: DepthPatch?)? {
        guard let seen = Projection.project(point, intrinsics: camera.intrinsics, pose: camera.pose) else {
            return nil
        }
        let box = WorldBox(centre: point, widthM: config.referenceSizeM, heightM: config.referenceSizeM)
        let patch = depth.flatMap {
            self.patch(of: box, in: $0, camera: camera,
                       maxColumns: config.referenceMaxCells, maxRows: config.referenceMaxCells)
        }
        return (seen.u, seen.v, patch)
    }
}
