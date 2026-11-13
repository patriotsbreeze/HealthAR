import ARKit
import Foundation
import PlumbGeometry

extension FramePipeline {
    /// A status snapshot when one is due, about `statusPerSecond` times a second of frame time.
    /// Counts the frame either way, for the frame rate.
    func status(at t: TimeInterval, tracking: ARCamera.TrackingState, camera: FrameCamera,
                handsPatch: DepthPatch?) -> CaptureStatus? {
        framesSinceStatus += 1
        guard let last = lastStatusT, t > last else {
            // The first frame, or a clock that did not move: start the count from here.
            lastStatusT = t
            framesSinceStatus = 0
            return nil
        }
        guard config.statusPerSecond > 0, t - last >= 1 / config.statusPerSecond else { return nil }
        let framesPerSecond = Double(framesSinceStatus) / (t - last)
        lastStatusT = t
        framesSinceStatus = 0

        let handsBox = hands.map { WorldBox(centre: $0.centre, widthM: config.handsWidthM, heightM: config.handsHeightM) }
        let referenceBox = reference.map { WorldBox(centre: $0, widthM: config.referenceSizeM, heightM: config.referenceSizeM) }
        // Only on status frames: a second look at the patch the estimator has already read.
        let filled = handsPatch.map {
            $0.nearestSurface(minConfidence: config.estimator.minConfidence, config: config.estimator.surface)?
                .validFraction ?? 0
        }
        return CaptureStatus(
            depthSupported: depthSupported,
            tracking: StatusWords.tracking(tracking),
            seeding: hands?.seeding ?? .unseeded,
            rangeM: hands == nil ? nil : estimator.rangeM,
            handsValidFraction: filled,
            referenceNoiseMM: estimator.referenceNoiseMM,
            framesPerSecond: framesPerSecond,
            handsRect: handsBox?.normalizedBounds(intrinsics: camera.intrinsics, pose: camera.pose),
            referenceRect: referenceBox?.normalizedBounds(intrinsics: camera.intrinsics, pose: camera.pose),
            thermal: StatusWords.thermal(ProcessInfo.processInfo.thermalState),
            isRecording: isRecording)
    }
}
