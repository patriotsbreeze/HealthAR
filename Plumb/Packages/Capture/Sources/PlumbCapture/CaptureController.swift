import ARKit
import Foundation
import os
import PlumbContracts
import PlumbGeometry

/// Runs the camera and LiDAR and turns every frame into a hand-height sample.
///
/// Threading: ARKit calls back on a private serial capture queue, and all per-frame work and
/// state live there. Calls from outside hop onto that queue; the few settings read every frame
/// (`method`, `automaticSeeding`, `onSample`, `onStatus`) and the guide placement written every
/// frame sit behind locks. Each member says where it may be used.
/// That confinement is why the class can promise `Sendable` without the compiler checking it.
public final class CaptureController: NSObject, @unchecked Sendable {
    /// The AR session, for `CameraView` to show. Read it anywhere; run and pause it only through
    /// `start` and `stop`, and never replace its delegate.
    public let session: ARSession

    /// Called with each new sample, on the capture queue. Set from any thread.
    public var onSample: (@Sendable (HeightSample) -> Void)? {
        get { settings.withLock { $0.onSample } }
        set { settings.withLock { $0.onSample = newValue } }
    }

    /// Called on the main thread with a status snapshot about five times a second. Set from any thread.
    public var onStatus: (@MainActor @Sendable (CaptureStatus) -> Void)? {
        get { settings.withLock { $0.onStatus } }
        set { settings.withLock { $0.onStatus = newValue } }
    }

    /// Called on the capture queue whenever the hands box is placed, moved or cleared, with how it
    /// now stands: on the frame that adopts a tap, when a body search lands, on `clearSeed` and on
    /// `start`. It comes in order with `onSample`, before the first sample of the new box, so a
    /// caller that hands both on in order through one serial queue can tell which box a sample came
    /// from. Set from any thread.
    public var onSeedChanged: (@Sendable (CaptureStatus.Seeding) -> Void)? {
        get { settings.withLock { $0.onSeedChanged } }
        set { settings.withLock { $0.onSeedChanged = newValue } }
    }

    /// Which height method is used. Read or set from any thread, also while running; a change takes
    /// effect from the next frame with a fresh estimator.
    public var method: HeightEstimator.Method {
        get { settings.withLock { $0.method } }
        set { settings.withLock { $0.method = newValue } }
    }

    /// Whether the body pose search may place the hands box by itself. Default true. Turn it off
    /// for a mode that relies on taps alone: no search starts, and a result still running is
    /// dropped. A box already placed stays until `clearSeed`. Read or set from any thread, also
    /// while running; a change takes effect from the next frame.
    public var automaticSeeding: Bool {
        get { settings.withLock { $0.automaticSeeding } }
        set { settings.withLock { $0.automaticSeeding = newValue } }
    }

    /// True when this phone has both world tracking and a LiDAR depth map. Read from any thread.
    public static var isSupported: Bool {
        ARWorldTrackingConfiguration.isSupported && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    private struct Settings: Sendable {
        var method: HeightEstimator.Method
        var automaticSeeding = true
        var onSample: (@Sendable (HeightSample) -> Void)?
        var onStatus: (@MainActor @Sendable (CaptureStatus) -> Void)?
        var onSeedChanged: (@Sendable (CaptureStatus.Seeding) -> Void)?
    }

    private let settings: OSAllocatedUnfairLock<Settings>
    /// Written on the capture queue after every frame; read by `CameraView.Coordinator` on the main thread.
    private let guides = OSAllocatedUnfairLock(initialState: GuidePlacement.none)
    private let captureQueue = DispatchQueue(label: "plumb.capture", qos: .userInteractive)
    /// Touched only on `captureQueue`.
    private let pipeline: FramePipeline
    private let config: CaptureConfig

    /// Makes a controller that is not yet running. Call from the main thread.
    public init(method: HeightEstimator.Method = .alongRay, config: CaptureConfig = .init()) {
        session = ARSession()
        settings = OSAllocatedUnfairLock(initialState: Settings(method: method))
        self.config = config
        pipeline = FramePipeline(config: config, method: method,
                                 depthSupported: ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth))
        super.init()
        session.delegate = self
        session.delegateQueue = captureQueue
        pipeline.seedChanged = { [weak self] seeding in
            self?.settings.withLock { $0.onSeedChanged }?(seeding)
        }
    }

    // MARK: - Running

    /// Starts (or restarts) world tracking with gravity-aligned axes and, where the phone has it,
    /// raw LiDAR depth. Forgets the hands box and stops any recording, because a restarted session
    /// has a new world and a new clock. Does nothing where world tracking is unsupported.
    /// Call from the main thread.
    public func start() {
        dispatchPrecondition(condition: .notOnQueue(captureQueue))
        guard ARWorldTrackingConfiguration.isSupported else { return }
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = []
        configuration.sceneReconstruction = []
        configuration.frameSemantics = Self.frameSemantics(peopleOcclusion: config.peopleOcclusion,
                                                           supports: ARWorldTrackingConfiguration.supportsFrameSemantics)
        // Pause first so no frame of the old run arrives after the restart; the restart then runs
        // behind any frame already queued. Otherwise an old frame could set the new clock or start
        // a body search whose world point belongs to the world about to be reset.
        session.pause()
        captureQueue.sync {
            pipeline.restart()
            guides.withLock { $0 = .none }
        }
        // Claimed again on every start in case anything else took the session's delegate meanwhile.
        session.delegate = self
        session.delegateQueue = captureQueue
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    /// Pauses the session, finishes any recording, drops any body search still running and answers
    /// any scene snapshot still waiting with nil. Call from the main thread.
    public func stop() {
        dispatchPrecondition(condition: .notOnQueue(captureQueue))
        session.pause()
        captureQueue.sync {
            pipeline.halt()
            guides.withLock { $0 = .none }
        }
    }

    /// The frame semantics to run with, given what `supports` says the phone can do: the raw depth
    /// map where it has one, never `.smoothedSceneDepth`, whose blending of frames would flatten
    /// strokes; and people segmentation with depth beside it when `peopleOcclusion` is wanted and
    /// the phone supports the two together. Never segmentation without the depth map: measuring
    /// comes first, and where the pair is unsupported occlusion is quietly left off.
    static func frameSemantics(peopleOcclusion: Bool,
                               supports: (ARConfiguration.FrameSemantics) -> Bool) -> ARConfiguration.FrameSemantics {
        guard supports(.sceneDepth) else { return [] }
        let occluding: ARConfiguration.FrameSemantics = [.sceneDepth, .personSegmentationWithDepth]
        return peopleOcclusion && supports(occluding) ? occluding : [.sceneDepth]
    }

    // MARK: - The hands box

    /// Places the hands box where the depth map says the surface is at this point of the picture:
    /// 0...1 across the camera's landscape image, origin at its top-left, as `CameraView` reports
    /// taps. Takes effect on the next frame with depth and normal tracking. Call from any thread.
    public func seed(atNormalizedImagePoint point: CGPoint) {
        captureQueue.async { [weak self] in self?.pipeline.requestTap(at: point) }
    }

    /// Forgets the hands box; the body pose search will look for the hands again. Call from any thread.
    public func clearSeed() {
        captureQueue.async { [weak self] in self?.pipeline.clearSeed() }
    }

    // MARK: - Guides

    /// Where the ring and the target line stand on the newest frame. Nothing placed while stopped.
    /// Read from any thread.
    var guidePlacement: GuidePlacement {
        guides.withLock { $0 }
    }

    /// Says whether compressions are under way, for the target line. Each time they start, or start
    /// again after a pause, the heights seen before are forgotten, because hands hovering or coming
    /// down onto the chest are not the top of a stroke. Call from any thread; it does not wait.
    public func setCompressing(_ on: Bool) {
        captureQueue.async { [weak self] in self?.pipeline.setCompressing(on) }
    }

    // MARK: - Recording

    /// Starts writing every measured frame to a new trace file in the app's Documents folder and
    /// returns its URL. Ends any recording already going. Throws when the file cannot be made.
    /// Call from the main thread; it waits briefly for the capture queue.
    public func startRecording(note: String) throws -> URL {
        dispatchPrecondition(condition: .notOnQueue(captureQueue))
        let now = Date()
        let url = try TraceNaming.newFileURL(at: now)
        let header = TraceHeader(createdAt: now, device: TraceNaming.deviceModel, note: note)
        try captureQueue.sync { try pipeline.startRecording(to: url, header: header) }
        return url
    }

    /// Finishes the trace file. When this returns every frame recorded is on disk and the file is
    /// closed. Call from the main thread.
    public func stopRecording() {
        dispatchPrecondition(condition: .notOnQueue(captureQueue))
        captureQueue.sync { pipeline.stopRecording() }
    }

    // MARK: - Scene snapshots

    /// A still of the scene from the next frame with depth and normal tracking, wholly detached
    /// from ARKit. Nil when this phone has no depth map, `stop` is called first, or no such frame
    /// comes within `CaptureConfig.snapshotTimeoutS`. Measuring goes on meanwhile: the frame is
    /// copied once in its usual pass on the capture queue, and turned into colour off that queue.
    /// Call from anywhere.
    public func snapshot() async -> SceneSnapshot? {
        let config = config
        let copy: SnapshotCopy? = await withCheckedContinuation { continuation in
            // Holds the controller until the request is answered: at most the timeout.
            captureQueue.async {
                let request = self.pipeline.requestSnapshot { continuation.resume(returning: $0) }
                self.captureQueue.asyncAfter(deadline: .now() + config.snapshotTimeoutS) {
                    self.pipeline.expireSnapshot(request)
                }
            }
        }
        return copy.flatMap { SceneSnapshot($0, minConfidence: config.probeMinConfidence) }
    }

    // MARK: - Body search

    /// Runs one body pose search off the capture queue and hands the result back to it.
    /// Called on the capture queue.
    private func launch(_ input: BodySearchInput) {
        let config = config
        Task.detached(priority: .userInitiated) { [weak self] in
            let hands = await BodySearch.run(input, config: config)
            guard let self else { return }
            self.captureQueue.async { self.pipeline.finishSearch(hands, generation: input.generation) }
        }
    }
}

// MARK: - ARSessionDelegate

extension CaptureController: ARSessionDelegate {
    /// Called by ARKit on the capture queue for every frame. The frame is read and let go here.
    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Every piece of capture state relies on this; a wrong queue would be a silent data race.
        dispatchPrecondition(condition: .onQueue(captureQueue))
        let current = settings.withLock { $0 }
        pipeline.automaticSeeding = current.automaticSeeding
        let outcome = pipeline.process(FrameInput(frame), method: current.method)
        guides.withLock { $0 = outcome.guides }
        if let sample = outcome.sample { current.onSample?(sample) }
        if let input = outcome.bodySearch { launch(input) }
        if let status = outcome.status, let onStatus = current.onStatus {
            DispatchQueue.main.async { MainActor.assumeIsolated { onStatus(status) } }
        }
    }
}
