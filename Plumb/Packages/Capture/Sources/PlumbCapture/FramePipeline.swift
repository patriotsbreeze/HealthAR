import ARKit
import CoreGraphics
import CoreVideo
import Foundation
import PlumbContracts
import PlumbGeometry

/// What one frame produced, for the controller to pass on.
struct FrameOutcome {
    /// The hands' height this frame, when it could be measured.
    var sample: HeightSample?
    /// A status snapshot, on the frames where one is due.
    var status: CaptureStatus?
    /// A body pose search to start, on the frames where one is due.
    var bodySearch: BodySearchInput?
    /// Where the ring and the target line stand after this frame.
    var guides = GuidePlacement.none
}

/// The box the hands move in: its centre, fixed in the world, and how it was placed.
struct HandsRegion: Sendable, Equatable {
    var centre: SIMD3<Double>
    var seeding: CaptureStatus.Seeding
}

/// Everything done with one camera frame, and the state carried from frame to frame.
///
/// Lives on the capture queue and is touched from nowhere else. Nothing of an ARFrame outlives
/// `process`: the depth map is copied, the luma plane is read in place, and the image is copied
/// only when a body search or a scene snapshot needs it.
final class FramePipeline {
    let config: CaptureConfig
    /// Whether this phone gives a depth map at all; without it no seed can be placed.
    let depthSupported: Bool
    var estimator: HeightEstimator

    /// Timestamp of the first frame since `restart`; frame times count from it.
    private var originTimestamp: TimeInterval?
    /// Time of the newest frame, in seconds since the first.
    private(set) var latestT: TimeInterval = 0

    var hands: HandsRegion?
    /// Laid once per seed so its spacing never changes; only its centre moves.
    var lumaGrid: LumaGrid?
    /// When the hands last gave a reading good enough to count.
    var lastValidT: TimeInterval = 0
    var trial: ReferenceTrial?
    var reference: SIMD3<Double>?
    /// Whether a body search may place the hands box. Set by the controller before each frame.
    var automaticSeeding = true
    /// The ring for the current hands box, fitted on the first frame with depth after it was placed.
    var ring: RingPlacement?
    /// The top of the stroke the hands come back up to, for the target line.
    var restTop: RestTopTracker
    /// Called on this queue whenever the hands box is placed, moved or cleared, with how it now
    /// stands. Called before the sample of the frame that placed it, so whoever is told in order
    /// can tell the samples of the old box from those of the new one.
    var seedChanged: ((CaptureStatus.Seeding) -> Void)?
    /// Whether compressions are under way, as the app last said; see `setCompressing`.
    private var compressing = false

    private var pendingTap: CGPoint?
    /// Bumped whenever the hands box changes or capture stops, so a body search started before
    /// then cannot overwrite what happened since.
    private var generation = 0
    private var searchInFlight = false
    private var lastSearchT: TimeInterval?
    private let copier = ImageCopier()
    /// Scene snapshot requests waiting for a frame with depth and normal tracking, by id.
    private var snapshotWaiters: [Int: (SnapshotCopy?) -> Void] = [:]
    private var lastSnapshotID = 0

    private var recorder: TraceWriter?
    var lastStatusT: TimeInterval?
    var framesSinceStatus = 0

    init(config: CaptureConfig, method: HeightEstimator.Method, depthSupported: Bool) {
        self.config = config
        self.depthSupported = depthSupported
        estimator = HeightEstimator(method: method, config: config.estimator)
        restTop = RestTopTracker(spanS: config.restTopSpanS, steadyS: config.restTopSteadyS,
                                 minReadings: config.restTopMinReadings)
    }

    /// True while frames are going to a trace file.
    var isRecording: Bool { recorder != nil }

    // MARK: - Each frame

    /// Measures one frame. Everything in `input` is read here and nothing of it is kept, apart
    /// from copies this package owns.
    func process(_ input: FrameInput, method: HeightEstimator.Method) -> FrameOutcome {
        if estimator.method != method {
            estimator = HeightEstimator(method: method, config: config.estimator)
        }
        let t = seconds(at: input.timestamp)
        let camera = input.camera
        let trackingNormal: Bool
        if case .normal = input.tracking { trackingNormal = true } else { trackingNormal = false }

        var outcome = FrameOutcome()
        // A seed is a world point: placed while tracking is unsure it lands in the wrong place.
        if trackingNormal, let depth = input.depth {
            seedFromTap(depth: depth, camera: camera, t: t)
            if ring == nil, let hands { ring = placeRing(around: hands.centre, depth: depth, camera: camera) }
            if !snapshotWaiters.isEmpty {
                deliverSnapshots(copier.copy(input.image).map {
                    SnapshotCopy(image: $0, depth: depth, camera: camera, timestamp: input.timestamp)
                })
            }
            if searchDue(at: t) {
                outcome.bodySearch = startSearch(image: input.image, depth: depth, camera: camera, t: t)
            }
        }

        var handsPatch: DepthPatch?
        var handsTopM: Double?
        // With no tracking at all the pose means nothing, so nothing is measured or recorded.
        let tracked: Bool
        if case .notAvailable = input.tracking { tracked = false } else { tracked = true }
        if tracked, let hands,
           let traced = measure(hands, camera: camera, depth: input.depth, image: input.image,
                                t: t, trackingNormal: trackingNormal) {
            handsPatch = traced.hands
            outcome.sample = estimator.ingest(traced)
            if let sample = outcome.sample, sample.quality >= config.validQuality { lastValidT = t }
            handsTopM = topOfHandsM(traced, sample: outcome.sample)
            record(traced)
        }
        if let handsTopM { restTop.add(handsTopM, at: t) } else { restTop.advance(to: t) }
        outcome.guides = guides(camera: camera, tracked: tracked)
        outcome.status = status(at: t, tracking: input.tracking, camera: camera, handsPatch: handsPatch)
        return outcome
    }

    private func seconds(at timestamp: TimeInterval) -> TimeInterval {
        let origin = originTimestamp ?? timestamp
        originTimestamp = origin
        latestT = timestamp - origin
        return latestT
    }

    // MARK: - Seeding

    /// Asks for the hands box to be placed at a normalised image point on the next frame with
    /// depth and normal tracking. Dropped on a phone without depth, where it could never be placed.
    func requestTap(at point: CGPoint) {
        guard depthSupported else { return }
        pendingTap = point
    }

    /// Forgets the hands box and any tap still waiting.
    func clearSeed() {
        pendingTap = nil
        adopt(nil, at: latestT)
    }

    /// Takes the result of a body search started by this pipeline.
    func finishSearch(_ point: SIMD3<Double>?, generation searched: Int) {
        searchInFlight = false
        guard automaticSeeding, searched == generation, let point, needsSeed(at: latestT) else { return }
        adopt(HandsRegion(centre: point, seeding: .automatic), at: latestT)
    }

    private func seedFromTap(depth: DepthMap, camera: FrameCamera, t: TimeInterval) {
        guard let tap = pendingTap else { return }
        pendingTap = nil
        let u = Double(tap.x) * Double(camera.intrinsics.width)
        let v = Double(tap.y) * Double(camera.intrinsics.height)
        let cells = DepthCells(intrinsics: camera.intrinsics, mapWidth: depth.width, mapHeight: depth.height)
        let window = cells.window(centredOnU: u, v: v, columns: config.probeCells, rows: config.probeCells)
        guard let depthM = depth.medianDepth(in: window, minConfidence: config.probeMinConfidence) else { return }
        let centre = Projection.unproject(u: u, v: v, depthM: depthM, intrinsics: camera.intrinsics, pose: camera.pose)
        adopt(HandsRegion(centre: centre, seeding: .tapped), at: t)
    }

    /// Unseeded, or seeded but without a valid reading for `reseedAfterS`.
    private func needsSeed(at t: TimeInterval) -> Bool {
        hands == nil || t - lastValidT >= config.reseedAfterS
    }

    /// At most one search in flight and at most `bodySearchesPerSecond` of them, and only when
    /// needed and allowed.
    private func searchDue(at t: TimeInterval) -> Bool {
        guard automaticSeeding, !searchInFlight, config.bodySearchesPerSecond > 0, needsSeed(at: t) else { return false }
        guard let last = lastSearchT else { return true }
        return t - last >= 1 / config.bodySearchesPerSecond
    }

    private func startSearch(image: CVPixelBuffer, depth: DepthMap, camera: FrameCamera,
                             t: TimeInterval) -> BodySearchInput? {
        lastSearchT = t
        guard let copy = copier.copy(image) else { return nil }
        searchInFlight = true
        return BodySearchInput(image: copy, depth: depth, camera: camera, generation: generation)
    }

    /// Puts a new hands box in place (or none) and starts everything that depends on it afresh.
    private func adopt(_ region: HandsRegion?, at t: TimeInterval) {
        hands = region
        lumaGrid = nil
        trial = nil
        reference = nil
        lastValidT = t
        generation += 1
        ring = nil
        restTop.reset()
        // Heights are relative to the box they were measured in; a new box starts a new trace.
        estimator.reset()
        seedChanged?(region?.seeding ?? .unseeded)
    }

    // MARK: - The top of the stroke

    /// Says whether compressions are under way. When they start, or start again after a pause, the
    /// tops seen so far are forgotten: they were heights of hands hovering or coming down onto the
    /// chest, which can be well above the top of a stroke, and the line would stand that much too
    /// high. The line comes back once enough tops have been seen since.
    func setCompressing(_ on: Bool) {
        if on, !compressing { restTop.reset() }
        compressing = on
    }

    // MARK: - Starting and stopping

    /// Clears everything for a new run of the session, whose clock and world start over. A scene
    /// snapshot still waiting is answered with nil: it was asked of the world now thrown away.
    func restart() {
        stopRecording()
        originTimestamp = nil
        latestT = 0
        pendingTap = nil
        compressing = false
        adopt(nil, at: 0)
        lastSearchT = nil
        lastStatusT = nil
        framesSinceStatus = 0
        deliverSnapshots(nil)
    }

    /// Stops recording, orphans any body search still running and answers every scene snapshot
    /// request still waiting with nil.
    func halt() {
        stopRecording()
        generation += 1
        deliverSnapshots(nil)
    }

    // MARK: - Scene snapshots

    /// Asks for a copy of the next frame with depth and normal tracking, and returns the id that
    /// expires the request. `deliver` is called exactly once, on this queue: with the copy, or with
    /// nil when the phone has no depth (straight away), the copy failed, the request expired or
    /// capture halted first. However many requests wait, a frame is copied once for all of them.
    func requestSnapshot(_ deliver: @escaping (SnapshotCopy?) -> Void) -> Int {
        lastSnapshotID += 1
        if depthSupported { snapshotWaiters[lastSnapshotID] = deliver } else { deliver(nil) }
        return lastSnapshotID
    }

    /// Answers a request still waiting with nil. Does nothing to one already answered.
    func expireSnapshot(_ id: Int) {
        snapshotWaiters.removeValue(forKey: id)?(nil)
    }

    /// Answers every waiting request with `copy` and forgets them all.
    private func deliverSnapshots(_ copy: SnapshotCopy?) {
        let waiting = snapshotWaiters.values
        snapshotWaiters = [:]
        for deliver in waiting { deliver(copy) }
    }

    // MARK: - Recording

    /// Starts writing every measured frame to a new trace file, ending any recording already going.
    func startRecording(to url: URL, header: TraceHeader) throws {
        stopRecording()
        recorder = try TraceWriter(url: url, header: header)
    }

    /// Finishes the trace file. Appends and this close both run on the capture queue, so a close
    /// never lands in the middle of a line.
    func stopRecording() {
        // A failed close leaves at worst a cut-off last line, which `TraceFile.decode` drops.
        try? recorder?.close()
        recorder = nil
    }

    private func record(_ frame: TraceFrame) {
        guard let recorder else { return }
        do {
            try recorder.append(frame)
        } catch {
            // Most likely a full disk. End the recording; every line already written stays readable.
            stopRecording()
        }
    }
}
