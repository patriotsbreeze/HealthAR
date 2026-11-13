import Foundation
import PlumbContracts
import simd

/// Turns camera frames into hand-height samples, by one of two independent methods.
///
/// Both give heights in millimetres that rise when the hands rise in the world, whatever the
/// camera's tilt or roll. Only differences between samples mean anything.
public struct HeightEstimator: Sendable {
    /// Which measurement the height comes from.
    public enum Method: String, Sendable, Codable, CaseIterable {
        /// The LiDAR range along the line of sight through the centre of the hands places them in
        /// the world; the height is that point's world height. Needs `handsU`/`handsV` to follow
        /// the hands and leans on the camera pose.
        case alongRay
        /// How far the picture of the hands has slid along world-up since a key frame, turned
        /// into millimetres with the LiDAR range as a ruler. Needs texture; ignores pose drift.
        case imagePlane
    }

    /// The method this estimator uses.
    public let method: Method
    /// The tunable numbers this estimator was made with.
    public let config: Config

    /// How much the patch that should be still appears to move, in millimetres: the standard
    /// deviation of its measured height over the last couple of seconds. The live noise floor.
    /// Nil while there is no reference.
    public private(set) var referenceNoiseMM: Double?
    /// Current straight-line distance from the camera to the hands, in metres, going by the tracked
    /// pixel and where the hands have stood over the last second. Nil until their range has been read.
    public private(set) var rangeM: Double?

    private var reference: ReferenceTracker
    private var ruler: FloorRuler
    /// Quality of the newest hands reading that went into the ruler.
    private var rulerQuality = 0.0
    private var picture: PictureTrack
    /// Height the current key frame stands for, so a new key frame carries on from the old one.
    private var keyHeightMM = 0.0
    private var lastHeightMM = 0.0

    /// Makes an estimator that has seen nothing yet.
    public init(method: Method, config: Config = .init()) {
        self.method = method
        self.config = config
        reference = ReferenceTracker(config: config)
        ruler = FloorRuler(spanS: config.rulerWindowS)
        picture = PictureTrack(config: config.shift)
    }

    /// Forgets everything seen so far, as if newly made.
    public mutating func reset() {
        self = HeightEstimator(method: method, config: config)
    }

    /// Takes in one frame and gives the hands' height for it, or nil when this frame cannot be
    /// measured: no readable hands patch (along-ray), or no luma patch or no range yet (image-plane).
    public mutating func ingest(_ frame: TraceFrame) -> HeightSample? {
        // The hands as the depth sensor places them this frame: where the line of sight through
        // their tracked centre meets the nearest surface in their patch.
        let sighting = frame.hands?
            .nearestSurface(minConfidence: config.minConfidence, config: config.surface)
            .map { reading in
                Sighting(reading: reading,
                         point: Projection.unproject(u: frame.handsU, v: frame.handsV, depthM: reading.depthM,
                                                     intrinsics: frame.intrinsics, pose: frame.pose))
            }
        let referenceSeen = observeReference(in: frame)
        observeRange(sighting, in: frame)

        let measured: (heightMM: Double, quality: Double)?
        switch method {
        case .alongRay: measured = alongRay(sighting, referenceSeen: referenceSeen)
        case .imagePlane: measured = imagePlane(frame)
        }
        guard let measured else { return nil }
        let quality = frame.trackingNormal ? measured.quality : min(measured.quality, config.notTrackingCap)
        return HeightSample(t: frame.t, heightMM: measured.heightMM, quality: min(max(quality, 0), 1))
    }

    // MARK: - Shared readings

    /// One frame's depth reading of the hands and the world point it puts them at.
    private struct Sighting {
        var reading: DepthPatch.Reading
        var point: SIMD3<Double>
    }

    /// Feeds the still patch to the reference tracker. True when it could be read this frame.
    private mutating func observeReference(in frame: TraceFrame) -> Bool {
        defer { referenceNoiseMM = reference.noiseMM }
        guard let patch = frame.reference, let u = frame.referenceU, let v = frame.referenceV,
              let reading = patch.nearestSurface(minConfidence: config.minConfidence, config: config.surface) else {
            reference.advance(to: frame.t)
            return false
        }
        let point = Projection.unproject(u: u, v: v, depthM: reading.depthM,
                                         intrinsics: frame.intrinsics, pose: frame.pose)
        reference.observe(heightMM: point.y * Self.millimetresPerMetre, at: frame.t)
        return true
    }

    private mutating func observeRange(_ sighting: Sighting?, in frame: TraceFrame) {
        if let sighting {
            ruler.add(sighting.point, at: frame.t)
            rulerQuality = patchQuality(sighting.reading)
        } else {
            ruler.advance(to: frame.t)
        }
        rangeM = handsPoint(in: frame).map { simd_distance($0, frame.pose.position) }
    }

    /// Where the hands are in the world now: on the line of sight through the tracked pixel, where
    /// it passes the spot on the floor plan the ruler remembers.
    private func handsPoint(in frame: TraceFrame) -> SIMD3<Double>? {
        ruler.spot.flatMap {
            Projection.point(onSightThroughU: frame.handsU, v: frame.handsV, above: $0,
                             intrinsics: frame.intrinsics, pose: frame.pose)
        }
    }

    /// Trust in one reading of the hands patch: full when the hands fill their share of the patch
    /// and look like one surface, less as either fails.
    private func patchQuality(_ reading: DepthPatch.Reading) -> Double {
        let fill = min(1, reading.validFraction / config.fullFillFraction)
        let calm = min(1, config.calmSpreadM / max(reading.spreadM, config.calmSpreadM))
        return fill * calm
    }

    // MARK: - Methods

    private func alongRay(_ sighting: Sighting?, referenceSeen: Bool) -> (heightMM: Double, quality: Double)? {
        guard let sighting else { return nil }
        let quality = patchQuality(sighting.reading) * (referenceSeen ? 1 : config.noReferenceFactor)
        return (sighting.point.y * Self.millimetresPerMetre - reference.correctionMM, quality)
    }

    private mutating func imagePlane(_ frame: TraceFrame) -> (heightMM: Double, quality: Double)? {
        let gridCentre = frame.handsLumaU.flatMap { u in frame.handsLumaV.map { SIMD2(u, $0) } }
        guard let luma = frame.handsLuma, let point = handsPoint(in: frame),
              let up = Projection.pixelsPerMetreAlongUp(at: point, intrinsics: frame.intrinsics, pose: frame.pose),
              let travel = picture.travel(of: luma, gridCentre: gridCentre, upDirection: up.direction) else {
            return nil
        }
        let quality = rulerQuality * travel.correlation
        guard travel.correlation >= config.rekeyCorrelation else {
            // The picture no longer looks like the key frame, so the slide cannot be believed.
            // Hold the last good height and start again from this frame.
            picture.restart(from: luma, gridCentre: gridCentre)
            keyHeightMM = lastHeightMM
            return (lastHeightMM, min(quality, config.rekeyQuality))
        }
        guard let riseM = Projection.riseM(endingAt: point, upPx: travel.upPx,
                                           intrinsics: frame.intrinsics, pose: frame.pose) else { return nil }
        lastHeightMM = keyHeightMM + riseM * Self.millimetresPerMetre
        return (lastHeightMM, quality)
    }

    private static let millimetresPerMetre = 1000.0
}
