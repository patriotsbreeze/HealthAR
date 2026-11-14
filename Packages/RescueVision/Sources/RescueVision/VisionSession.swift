import CoreGraphics
import CoreVideo
import Foundation
import RescueCore
import Synchronization
import simd

/// A frame cleared for the model. The engine's policy can change while this is in transit, so
/// the sender should still check the current policy right before sending.
public struct UplinkFrame: Sendable, Equatable {
    public var frameID: UInt64
    public var jpeg: Data
    public var capturedAt: TimeInterval
}

public enum VisionStatus: String, Sendable, Equatable {
    /// No world tracking here, as in the Simulator. Everything no-ops.
    case unsupported
    case stopped
    case running
    case shedForHeat = "shed_for_heat"
    /// The AR session failed, for example no camera permission. `start()` tries again.
    case failed
}

/// The camera behind a session, so the pipeline can be tested without ARKit.
protocol CameraDriver: AnyObject, Sendable {
    var isSupported: Bool { get }
    /// Always starts a new world. See `VisionSession.forgetWorld()`.
    func run()
    func pause()
    /// Where the ray meets a surface, or failing that the floor, which still gives an AED's direction.
    func surfacePoint(along ray: WorldRay) async -> SIMD3<Float>?
    /// Only a surface the ray really meets. A pin on the floor behind a limb is worse than none.
    func surfaceHit(along ray: WorldRay) async -> SIMD3<Float>?
}

extension CameraDriver {
    /// For a driver with no floor to fall back on.
    func surfaceHit(along ray: WorldRay) async -> SIMD3<Float>? { await surfacePoint(along: ray) }
}

#if !os(iOS)
/// Stands in where ARKit doesn't exist.
final class NoCamera: CameraDriver {
    var isSupported: Bool { false }
    func run() {}
    func pause() {}
    func surfacePoint(along ray: WorldRay) async -> SIMD3<Float>? { nil }
}
#endif

/// The one type a coordinator drives. Forward engine effects to `apply`, draw `overlay()` each
/// display frame, and send what arrives on `uplinkFrames`. Every call returns at once from any
/// thread, and nothing here can hold up guidance.
public final class VisionSession: Sendable {
    /// How long the hands guide shows at the start of compressions.
    public static let handsGuideSeconds: TimeInterval = 8

    private struct State {
        var ledger = FrameLedger()
        var mapping: DisplayMapping?
        var viewport = CGSize.zero
        var overlayTarget: OverlayTarget?
        var targetEnteredAt: TimeInterval = 0
        /// Opened by the coordinator as compressions begins. Any overlay change ends it.
        var handsGuide: Range<TimeInterval>?
        var ring = RingController()
        var uplink = FrameUplinkPolicy()
        /// Single frozen frames may go to the locator, and nowhere else. Apart from the uplink, so
        /// a step can find a towel without streaming anything to the model.
        var locateOpen = false
        var load = ThermalGovernor.load(for: .nominal)
        var pendingLocate: Set<Material> = []
        var pendingLocateCarries = false
        var aedFindsCarry = false
        var showsCarriedAED = false
        /// Materials this step points at. Only these get callouts.
        var wanted: Set<Material> = []
        var injuryPin: PlacedPin?
        var pinRequestID: UInt64 = 0
        var lastPoseAt = -TimeInterval.infinity
        /// Where the ghost rescuer kneels, from the chest pose. Kept across steps until the world is forgotten.
        var ghostAnchor: GhostAnchor?
        /// The anchor came from a tap on the floor, so an imaginary patient draws under the ghost.
        var ghostPractice = false
        var practiceRequestID: UInt64 = 0
        var lastGhostLockAt = -TimeInterval.infinity
        /// When the metronome last turned on, which starts its beat grid afresh.
        var ghostBeatStart: TimeInterval?
        var coach = CompressionCoach()
        /// Bumped whenever the world is forgotten, so a raycast that started before lands nowhere.
        var worldEpoch: UInt64 = 0
        var wantsRunning = false
        var arActive = false
        var patientModelReady = false
        var failed = false

        enum DriverAction { case none, run, pause }

        mutating func reconcile() -> DriverAction {
            let desired = wantsRunning && load.arEnabled
            guard desired != arActive else { return .none }
            arActive = desired
            return desired ? .run : .pause
        }

        var mayLocate: Bool { locateOpen || uplink.isOpen }

        /// A towel, pillow or gloves only where the step lets frozen frames go to the locator, so
        /// never on the arrest path, where the uplink is open. The AED goes as it always has, on
        /// either gate.
        func mayLocate(_ material: Material) -> Bool {
            material == .aed ? mayLocate : locateOpen
        }

        /// After either gate changes: what may no longer go is dropped, whatever else is still open.
        mutating func dropClosedLocates() {
            pendingLocate = pendingLocate.filter { mayLocate($0) }
        }

        func pinLive(at now: TimeInterval) -> Bool {
            injuryPin.map { now - $0.placedAt < VisionOverlay.pinSeconds } ?? false
        }

        func showsHandsGuide(at now: TimeInterval) -> Bool {
            overlayTarget == nil && (handsGuide?.contains(now) ?? false)
        }

        func poseDemand(at now: TimeInterval, holdsLimb: Bool) -> PoseDemand {
            PoseDemand.demand(
                target: overlayTarget,
                enteredAt: targetEnteredAt,
                handsGuide: handsGuide,
                pinLive: pinLive(at: now),
                holdsLimb: holdsLimb,
                coaching: coaching,
                now: now
            )
        }

        func handsPlacement(at now: TimeInterval) -> HandsPlacement? {
            guard overlayTarget == .chestCenter || showsHandsGuide(at: now), let anchor = ghostAnchor,
                  let camera = ledger.latest, camera.tracking == .normal,
                  now - camera.timestamp <= VisionOverlay.maxCameraAge
            else { return nil }
            return HandsPlacement(transform: simd_float4x4(columns: (
                SIMD4(anchor.headward, 0),
                SIMD4(GhostAnchor.up, 0),
                SIMD4(anchor.side, 0),
                SIMD4(anchor.chest, 1)
            )))
        }

        /// The ghost is up and pushing, so the person compressing is measured against it.
        var coaching: Bool { overlayTarget == nil && ghostAnchor != nil && ghostBeatStart != nil }

        func feedback(at now: TimeInterval) -> CompressionFeedback? {
            guard coaching else { return nil }
            return coach.feedback(at: now, beatStart: ghostBeatStart, interval: GhostRescuer.beatInterval)
        }

        func needsPixels(at now: TimeInterval, holdsLimb: Bool) -> Bool {
            arActive || poseDemand(at: now, holdsLimb: holdsLimb) != .none || uplink.isOpen || !pendingLocate.isEmpty
        }

        /// The pin in this frame's capture image, while it lasts and is in front of the camera.
        func pinAnchor(in record: FrameRecord, at now: TimeInterval) -> SIMD2<Double>? {
            guard let injuryPin, pinLive(at: now), case let .inFront(image) = record.pose.project(injuryPin.world) else { return nil }
            return image
        }
    }

    private struct FrameJob {
        var record: FrameRecord
        var locate: Set<Material>
        var locateCarries: Bool
        var sendUplink: Bool
        var pose: PoseRequest?
    }

    /// Upright in the app, which is portrait-locked.
    private static let jpegRotation = CaptureRotation.right

    private let state = Mutex(State())
    let driver: any CameraDriver
    private let clock: @Sendable () -> TimeInterval
    private let encode: @Sendable (CapturedFrame, CaptureRotation) async -> Data?
    private let thermalTask = Mutex<Task<Void, Never>?>(nil)
    let pose: PoseWorker
    let objects: ObjectLocator

    let frames: AsyncStream<CapturedFrame>
    private let framesContinuation: AsyncStream<CapturedFrame>.Continuation
    /// Latest wins, so a slow socket can't build a queue. Has one consumer.
    public let uplinkFrames: AsyncStream<UplinkFrame>
    private let uplinkContinuation: AsyncStream<UplinkFrame>.Continuation
    /// Callers waiting on the next frame as a JPEG, each with its own deadline.
    private let snapshotWaiters = Mutex<[UInt64: CheckedContinuation<Data?, Never>]>([:])
    private let nextSnapshotID = Mutex<UInt64>(0)

    /// On a device this owns the AR session. In the Simulator and on macOS it is a clean no-op.
    public convenience init(locator: any ObjectLocating) {
        #if os(iOS)
        let driver = ARController()
        #else
        let driver = NoCamera()
        #endif
        let detector = VisionPoseDetector()
        self.init(
            locator: locator,
            driver: driver,
            detect: { await detector.detect($0, rotation: $1) },
            detectFrame: { await detector.detectFrame($0, rotation: $1) },
            clock: { ProcessInfo.processInfo.systemUptime },
            runsPump: true
        )
        #if os(iOS)
        driver.sink = self
        #endif
        observeThermalState()
    }

    init(
        locator: any ObjectLocating,
        driver: any CameraDriver,
        detect: @escaping PoseDetector,
        detectFrame: PoseFrameDetector? = nil,
        clock: @escaping @Sendable () -> TimeInterval,
        runsPump: Bool,
        encode: (@Sendable (CapturedFrame, CaptureRotation) async -> Data?)? = nil
    ) {
        self.driver = driver
        self.clock = clock
        let encoder = FrameEncoder()
        self.encode = encode ?? { await encoder.encode($0, rotation: $1) }
        pose = PoseWorker(detect: detect, detectFrame: detectFrame)
        objects = ObjectLocator(locator: locator, clock: clock) { [driver] ray in
            await driver.surfacePoint(along: ray)
        }

        // One buffered frame plus the one being worked on: at most 2 pixel buffers are ever
        // held however slow inference gets, so the camera's buffer pool can't starve.
        (frames, framesContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (uplinkFrames, uplinkContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))

        if runsPump {
            Task.detached(priority: .userInitiated) { [weak self, frames] in
                for await frame in frames {
                    guard let self else { return }
                    await self.process(frame)
                }
            }
        }
    }

    deinit {
        finishStreams()
        thermalTask.withLock { $0?.cancel() }
    }

    func finishStreams() {
        framesContinuation.finish()
        uplinkContinuation.finish()
        resumeSnapshots(with: nil)
    }

    /// The next camera frame as a JPEG, or nil if none comes before the deadline. The caller decides
    /// whether a frame may leave the phone; this only takes the picture.
    public func snapshot(timeout: TimeInterval = 1.5) async -> Data? {
        let id = nextSnapshotID.withLock { $0 += 1; return $0 }
        return await withCheckedContinuation { continuation in
            snapshotWaiters.withLock { $0[id] = continuation }
            Task.detached { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.snapshotWaiters.withLock { $0.removeValue(forKey: id) }?.resume(returning: nil)
            }
        }
    }

    private func resumeSnapshots(with jpeg: Data?) {
        let waiting = snapshotWaiters.withLock { waiters in
            defer { waiters = [:] }
            return Array(waiters.values)
        }
        waiting.forEach { $0.resume(returning: jpeg) }
    }

    // MARK: - Driving

    public var isARSupported: Bool { driver.isSupported }

    public var status: VisionStatus {
        guard driver.isSupported else { return .unsupported }
        return state.withLock { state in
            if state.failed { return .failed }
            if state.arActive { return .running }
            return state.wantsRunning ? .shedForHeat : .stopped
        }
    }

    public func start() {
        guard driver.isSupported else { return }
        perform(state.withLock { state in
            state.wantsRunning = true
            state.failed = false
            return state.reconcile()
        })
    }

    public func stop() {
        perform(state.withLock { state in
            state.wantsRunning = false
            state.failed = false
            return state.reconcile()
        })
        forgetWorld()
    }

    /// Forward every engine effect. The ones vision has no part in are ignored.
    public func apply(_ effect: RescueEffect) {
        switch effect {
        case let .overlay(target): setOverlayTarget(target)
        // The engine sends these right after the overlay, which clears what the last step wanted.
        case let .cues(cues): setWantedMaterials(Set(cues.compactMap(\.material)))
        case let .policyChanged(policy):
            setFrameUplink(policy.frameUplink, burstsOnly: policy.frameBurstsOnly)
            // Each policy says again whether frozen frames may go to the locator alone, so a call
            // starting, or a step without the permission, shuts it.
            setLocateOpen(policy.frameLocate)
            setAEDCarry(findsCarry: policy.aedFindsCarry, showsCarried: policy.showsCarriedAED)
        case let .locate(object):
            if let material = Material(rawValue: object.rawValue) { requestLocate(material) }
        default: break
        }
    }

    /// Frames at 1 per second for 3 s, for example on speech onset or at the start of a scan.
    /// Ignored while the engine has the uplink closed.
    public func beginFrameBurst() {
        let now = clock()
        state.withLock { $0.uplink.beginBurst(at: now) }
    }

    /// Lets single frozen frames go to the locator, and nowhere else, while the uplink stays as the
    /// engine set it. Every policy change sets it again from `frameLocate`.
    public func setLocateOpen(_ open: Bool) {
        state.withLock { state in
            state.locateOpen = open
            state.dropClosedLocates()
        }
    }

    /// Looks for these on the next frame with good tracking, in one call. Ignored unless frozen
    /// frames may go to the locator here, and for anything already being looked for.
    public func requestLocate(_ materials: Set<Material>) {
        guard driver.isSupported, !materials.isEmpty else { return }
        // One in flight answers for itself. Asking again would void it and pay for another.
        let asked = materials.filter { objects.status($0) != .locating }
        guard !asked.isEmpty else { return }
        state.withLock { state in
            // The safety gate already checked the AED against the state definition, and the step
            // decides the rest: materials only on the locate gate, never on the uplink alone. A call
            // becoming active closes both gates.
            let allowed = asked.filter { state.mayLocate($0) }
            guard !allowed.isEmpty else { return }
            state.pendingLocate.formUnion(allowed)
            if allowed.contains(.aed) { state.pendingLocateCarries = state.aedFindsCarry }
        }
    }

    public func requestLocate(_ material: Material) { requestLocate([material]) }

    /// The materials this step points at. The step's `.cues` effect sets it, after the overlay change
    /// that clears it. Only these get callouts, and never the AED, which has its arrow.
    public func setWantedMaterials(_ materials: Set<Material>) {
        state.withLock { $0.wanted = materials }
    }

    /// The chest zone and ring for the first seconds of compressions, which the core reaches
    /// straight from Start CPR without ever showing place_hands. Call it after forwarding the
    /// entry's effects, since every overlay change ends it. It needs a step with no overlay of its
    /// own, runs pose on the phone only, sends nothing, and gates nothing.
    public func beginHandsGuide(seconds: TimeInterval = VisionSession.handsGuideSeconds) {
        guard driver.isSupported, seconds > 0 else { return }
        let now = clock()
        state.withLock { state in
            guard state.overlayTarget == nil else { return }
            state.handsGuide = now..<(now + seconds)
            state.ring.enterState(at: now, until: now + seconds)
        }
    }

    /// The ghost rescuer pushes on the metronome's beat. The metronome starts its grid each time it
    /// turns on, so this stamps that moment, and a repeat while it is on changes nothing.
    public func setGhostBeat(on: Bool) {
        let now = clock()
        state.withLock { state in
            if !on {
                state.ghostBeatStart = nil
                state.coach.reset()
            } else if state.ghostBeatStart == nil {
                state.ghostBeatStart = now
                state.coach.reset()
            }
        }
    }

    /// The ghost has a place to kneel, for the latency HUD and tests.
    public var hasGhostAnchor: Bool { state.withLock { $0.ghostAnchor != nil } }

    /// The metronome's interval, which the ghost's push follows. The app checks it against the audio's.
    public static let ghostBeatInterval = GhostRescuer.beatInterval

    /// Lays an imaginary patient on the floor at a point on screen, the view's centre by default,
    /// with the ghost rescuer kneeling beside it, for practice with no one lying down. Raycasts only,
    /// on the phone. A chest found later by pose takes over from it.
    @discardableResult
    public func placePracticePatient(atViewPoint point: CGPoint? = nil) async -> Bool {
        let request: (id: UInt64, ray: WorldRay, camera: CameraPose, epoch: UInt64)? = state.withLock { state in
            guard let camera = state.ledger.latest, camera.tracking == .normal,
                  clock() - camera.timestamp <= VisionOverlay.maxCameraAge,
                  let mapping = state.mapping
            else { return nil }
            let screen = point ?? CGPoint(x: state.viewport.width / 2, y: state.viewport.height / 2)
            guard let image = mapping.imagePoint(fromScreen: screen) else { return nil }
            state.practiceRequestID += 1
            return (state.practiceRequestID, camera.pose.ray(throughImagePoint: image), camera.pose, state.worldEpoch)
        }
        guard let request, let floor = await driver.surfacePoint(along: request.ray),
              let anchor = GhostAnchor(floor: floor, camera: request.camera.position, cameraDown: request.camera.screenDown)
        else { return false }
        return state.withLock { state in
            guard state.practiceRequestID == request.id, state.worldEpoch == request.epoch else { return false }
            state.ghostAnchor = anchor
            state.ghostPractice = true
            return true
        }
    }

    public func clearPracticePatient() {
        state.withLock { state in
            state.practiceRequestID += 1
            guard state.ghostPractice else { return }
            state.ghostAnchor = nil
            state.ghostPractice = false
        }
    }

    public var hasPracticePatient: Bool { state.withLock { $0.ghostPractice } }

    public func endHandsGuide() {
        state.withLock { state in
            guard state.handsGuide != nil else { return }
            state.handsGuide = nil
            state.ring.leaveState()
        }
    }

    /// True while the hands guide is up, so a view knows to keep drawing.
    public var showsHandsGuide: Bool {
        let now = clock()
        return state.withLock { $0.showsHandsGuide(at: now) }
    }

    /// A tap on the camera view, in view points. It sends nothing anywhere: the ray comes from the
    /// latest frame's pose, and a later tap or a break in tracking voids this one.
    public func placeInjuryPin(atViewPoint point: CGPoint) async -> InjuryPinResult {
        let now = clock()
        let request: (id: UInt64, ray: WorldRay)? = state.withLock { state in
            guard state.overlayTarget == .injurySite,
                  let camera = state.ledger.latest, camera.tracking == .normal,
                  now - camera.timestamp <= VisionOverlay.maxCameraAge,
                  let image = state.mapping?.imagePoint(fromScreen: point)
            else { return nil }
            state.pinRequestID += 1
            return (state.pinRequestID, camera.pose.ray(throughImagePoint: image))
        }
        guard let request else { return .notPlaced }
        let hit = await driver.surfaceHit(along: request.ray)
        let placedAt = clock()
        return state.withLock { state in
            guard state.pinRequestID == request.id else { return .superseded }
            guard let hit else { return .notPlaced }
            state.injuryPin = PlacedPin(world: hit, placedAt: placedAt)
            return .placed
        }
    }

    // MARK: - Reading

    /// Called only after the renderer has loaded both patient meshes successfully.
    func patientModelDidLoad() { state.withLock { $0.patientModelReady = true } }

    /// Depth-backed patient template. It expires instead of staying at an old body location.
    public func patientBodyPlacement() -> PatientBodyPlacement? {
        let now = clock()
        guard let fitted = pose.patientBody, (0...VisionOverlay.maxJointAge).contains(now - fitted.capturedAt) else { return nil }
        return state.withLock { state in
            guard state.arActive, let camera = state.ledger.latest, camera.tracking == .normal,
                  (0...VisionOverlay.maxCameraAge).contains(now - camera.timestamp),
                  state.mapping != nil, !state.ghostPractice else { return nil }
            var placement = fitted.placement
            placement.showsChestEstimate = state.overlayTarget == .chestCenter || state.showsHandsGuide(at: now)
            return placement
        }
    }

    /// The overlay for this instant, cheap enough to call every display frame.
    public func overlay() -> VisionOverlay {
        let now = clock()
        let (latest, latestPose) = pose.snapshot
        let aedPoint = objects.worldPoint(.aed)
        let carriedPoint = objects.carriedPoint(.aed)
        let callouts = objects.callouts()
        var overlay = state.withLock { state in
            VisionOverlay.compose(
                target: state.overlayTarget,
                ring: state.ring.output(latest: latest, at: now),
                camera: state.ledger.latest,
                mapping: state.mapping,
                aedPoint: aedPoint,
                carriedAED: state.showsCarriedAED ? carriedPoint : nil,
                injuryPin: state.injuryPin,
                pose: latestPose,
                jointPose: pose.jointPose,
                items: callouts.filter { state.wanted.contains($0.key) },
                handsGuide: state.showsHandsGuide(at: now),
                ghost: state.ghostAnchor.flatMap { anchor in
                    state.ghostBeatStart.map {
                        (anchor, GhostRescuer.push(sinceBeatStart: now - $0, beatInterval: GhostRescuer.beatInterval), state.ghostPractice)
                    }
                },
                now: now
            )
        }
        // The 3D hands take over from the flat ones wherever they show.
        let patientBody = patientBodyPlacement()
        overlay.patientIn3D = patientBody != nil && state.withLock { $0.patientModelReady }
        if overlay.patientIn3D {
            overlay.chestEstimateLabel = patientBody?.showsChestEstimate == true
                ? "Estimated hand placement - Not a sternum detection"
                : "3D body fit - Template estimate"
        }
        overlay.handsIn3D = (overlay.patientIn3D && patientBody?.showsChestEstimate == true) || handsPlacement() != nil
        return overlay
    }

    /// Maps capture image space to the screen for the latest frame. Nil before a viewport is
    /// known or when AR isn't running.
    public var displayMapping: DisplayMapping? { state.withLock { $0.mapping } }

    public var latestTarget: TimedTorsoTarget? { pose.latest }
    /// Why the latest pose frame gave no target, for the latency HUD.
    public var lastNoTargetReason: NoTargetReason? { pose.lastNoTargetReason }
    public var keypointAge: TimeInterval? { pose.latestPose?.age(at: clock()) }
    public var aedStatus: AEDStatus { objects.status(.aed) }

    public func locateStatus(_ material: Material) -> AEDStatus { objects.status(material) }

    /// Times located in a row at about one spot. A callout shows from the second, so a step that
    /// wants one keeps asking until then.
    public func sightings(of material: Material) -> Int { objects.sightings(material) }

    // MARK: - Internal steps, driven directly by tests

    func setOverlayTarget(_ target: OverlayTarget?) {
        let now = clock()
        let changed = state.withLock { state in
            let changed = state.overlayTarget != target
            state.overlayTarget = target
            state.targetEnteredAt = now
            state.handsGuide = nil
            state.wanted = []
            if target == .chestCenter {
                state.ring.enterState(at: now)
            } else {
                state.ring.leaveState()
            }
            // The steps that draw the pin share it. Kept past them, it would come back on a later one nobody tapped.
            if target != .injurySite {
                state.injuryPin = nil
                state.pinRequestID += 1
            }
            return changed
        }
        // A different kind of step starts pose afresh, so nothing found for the last one shows on this one.
        if changed { pose.reset() }
    }

    func setFrameUplink(_ open: Bool, burstsOnly: Bool = false) {
        state.withLock { state in
            state.uplink.setOpen(open)
            state.uplink.setBurstsOnly(burstsOnly)
            state.dropClosedLocates()
        }
    }

    func setAEDCarry(findsCarry: Bool, showsCarried: Bool) {
        state.withLock { state in
            state.aedFindsCarry = findsCarry
            state.showsCarriedAED = showsCarried
        }
    }

    func setThermalState(_ thermal: ProcessInfo.ThermalState) {
        let load = ThermalGovernor.load(for: thermal)
        perform(state.withLock { state in
            state.load = load
            state.uplink.setIntervalScale(load.uplinkIntervalScale)
            return state.reconcile()
        })
    }

    private func observeThermalState() {
        setThermalState(ProcessInfo.processInfo.thermalState)
        let task = Task.detached { [weak self] in
            let changes = NotificationCenter.default.notifications(named: ProcessInfo.thermalStateDidChangeNotification)
            for await _ in changes {
                self?.setThermalState(ProcessInfo.processInfo.thermalState)
            }
        }
        thermalTask.withLock { $0 = task }
    }

    private func perform(_ action: State.DriverAction) {
        switch action {
        case .none:
            break
        case .run:
            driver.run()
        case .pause:
            driver.pause()
            forgetWorld()
        }
    }

    /// After any break in tracking the old world coordinates can't be trusted, and an arrow to
    /// a stale point is worse than none. Voice carries on, and a new locate can place it again.
    func forgetWorld() {
        state.withLock { state in
            state.pendingLocate = []
            state.mapping = nil
            state.ledger.removeAll()
            state.injuryPin = nil
            state.pinRequestID += 1
            state.ghostAnchor = nil
            state.ghostPractice = false
            state.worldEpoch += 1
        }
        objects.clear()
        pose.reset()
    }

    // MARK: - Frames in

    var viewportSize: CGSize {
        get { state.withLock { $0.viewport } }
        set { state.withLock { $0.viewport = newValue } }
    }

    /// Called from the AR delegate, so it only copies values and hands off the pixels. Returns
    /// the frame if anything wants its pixels right now.
    @discardableResult
    func ingest(
        pixels: CVPixelBuffer,
        pose: CameraPose,
        tracking: TrackingQuality,
        imageToView: CGAffineTransform?,
        bodyDepth: BodyDepth? = nil
    ) -> CapturedFrame? {
        // Stamped here rather than from ARFrame.timestamp, whose clock Apple doesn't document,
        // so every age in this package reads one clock. It under-counts by the delivery delay.
        let now = clock()
        let holdsLimb = self.pose.holdsLimb
        let wanted: UInt64? = state.withLock { state in
            let record = state.ledger.record(timestamp: now, pose: pose, tracking: tracking)
            state.mapping = imageToView.map {
                DisplayMapping(imageToView: $0, viewSize: state.viewport, imageAspect: pose.imageAspect)
            }
            return state.needsPixels(at: now, holdsLimb: holdsLimb) ? record.id : nil
        }
        guard let wanted else { return nil }
        let frame = CapturedFrame(id: wanted, pixels: pixels, bodyDepth: bodyDepth)
        framesContinuation.yield(frame)
        return frame
    }

    private func coach(_ sample: CompressionSample?, record: FrameRecord) {
        state.withLock { state in
            guard state.coaching, let sample, let anchor = state.ghostAnchor else { return }
            // Where the ghost's hands are in this frame, and how many image heights a metre is there.
            var chest: (point: SIMD2<Double>, perMetre: Double)?
            if case let .inFront(a) = record.pose.project(anchor.chest),
               case let .inFront(b) = record.pose.project(anchor.chest + anchor.headward * 0.3) {
                let metre = simd_length((b - a) * SIMD2(record.pose.imageAspect, 1)) / 0.3
                chest = (a, metre)
            }
            state.coach.add(sample, at: record.timestamp, chest: chest, imageAspect: record.pose.imageAspect)
        }
    }

    /// The 3D ghost for this instant, on the same terms as the overlay's: a step with no mark of its
    /// own, a place to kneel, the beat on, and a fresh camera with normal tracking.
    public func ghostPlacement() -> GhostPlacement? {
        let now = clock()
        return state.withLock { state in
            guard state.overlayTarget == nil, let anchor = state.ghostAnchor, let start = state.ghostBeatStart,
                  let camera = state.ledger.latest, camera.tracking == .normal,
                  now - camera.timestamp <= VisionOverlay.maxCameraAge
            else { return nil }
            let tone: GhostPlacement.Tone = switch state.feedback(at: now) {
            case let feedback? where feedback.matchesGhost: .matching
            case let feedback? where feedback.cue != nil: .correcting
            default: .neutral
            }
            return GhostPlacement(
                transform: simd_float4x4(columns: (
                    SIMD4(anchor.headward, 0),
                    SIMD4(GhostAnchor.up, 0),
                    SIMD4(anchor.side, 0),
                    SIMD4(anchor.chest, 1)
                )),
                push: GhostRescuer.push(sinceBeatStart: now - start, beatInterval: GhostRescuer.beatInterval),
                practice: state.ghostPractice,
                patientScale: anchor.bodyScale,
                tone: tone
            )
        }
    }

    /// The ghost is on screen and pushing on the beat, so it can stand in for the Push pulse.
    public var showsGhost: Bool { ghostPlacement() != nil }

    /// The stacked hands on the chest, while the step shows where they go: place_hands, or the hands
    /// guide at the start of compressions. Needs the chest placed in the world and a fresh camera
    /// with normal tracking, like every world mark.
    public func handsPlacement() -> HandsPlacement? {
        let now = clock()
        return state.withLock { $0.handsPlacement(at: now) }
    }

    /// How the person compressing compares with the ghost, or nil while there's no ghost to follow or
    /// nobody has been seen compressing lately.
    public func compressionFeedback() -> CompressionFeedback? {
        let now = clock()
        return state.withLock { $0.feedback(at: now) }
    }

    /// How often the ghost's place is found again while the chest is in view, so it settles on a
    /// steady pose rather than the first one.
    static let ghostRelock: TimeInterval = 0.5

    /// Places the ghost from this frame's chest, on place_hands or in the hands guide, where pose is
    /// already running on the lying patient. Raycasts only, on the phone, and nothing waits on it.
    private func lockGhost(after record: FrameRecord) {
        let now = clock()
        let latest = pose.latest
        let epoch: UInt64? = state.withLock { state in
            guard state.overlayTarget == .chestCenter || state.showsHandsGuide(at: now),
                  record.tracking == .normal,
                  latest?.frameID == record.id,
                  now - state.lastGhostLockAt >= Self.ghostRelock
            else { return nil }
            state.lastGhostLockAt = now
            return state.worldEpoch
        }
        guard let epoch, let latest else { return }
        let camera = record.pose
        Task.detached { [weak self, driver] in
            guard let chest = await driver.surfaceHit(along: camera.ray(throughImagePoint: latest.target.center)) else { return }
            var shoulders: SIMD3<Float>?, hips: SIMD3<Float>?
            if let image = latest.shoulders {
                shoulders = await driver.surfaceHit(along: camera.ray(throughImagePoint: image))
            }
            if let image = latest.hips {
                hips = await driver.surfaceHit(along: camera.ray(throughImagePoint: image))
            }
            guard let anchor = GhostAnchor(
                chest: chest, shoulders: shoulders, hips: hips, camera: camera.position, cameraDown: camera.screenDown
            ) else { return }
            self?.state.withLock { state in
                guard state.worldEpoch == epoch else { return }
                state.ghostAnchor = anchor
                // A real body wins over the practice one.
                state.ghostPractice = false
                state.practiceRequestID += 1
            }
        }
    }

    func driverFailed() {
        state.withLock { state in
            state.failed = true
            state.wantsRunning = false
            state.arActive = false
        }
        forgetWorld()
    }

    /// Returns true if this frame went out on the uplink.
    @discardableResult
    func process(_ frame: CapturedFrame) async -> Bool {
        if snapshotWaiters.withLock({ !$0.isEmpty }) {
            resumeSnapshots(with: await encode(frame, Self.jpegRotation))
        }
        let now = clock()
        let holdsLimb = pose.holdsLimb
        let job: FrameJob? = state.withLock { state in
            guard let record = state.ledger.entry(for: frame.id) else { return nil }
            var locate: Set<Material> = []
            // Wait for good tracking. A located point is only as good as the stored pose.
            if record.tracking == .normal {
                locate = state.pendingLocate.filter { state.mayLocate($0) }
                state.pendingLocate.subtract(locate)
            }
            let demand = state.poseDemand(at: now, holdsLimb: holdsLimb)
            // Joint visualization runs locally whenever the camera is active, including intake
            // and an untapped injury view. It never opens either network gate.
            let rate = demand == .none && state.arActive
                ? min(state.load.poseFramesPerSecond, 10)
                : demand.framesPerSecond(load: state.load, now: now)
            var request: PoseRequest?
            if rate > 0, now - state.lastPoseAt >= 1 / rate {
                state.lastPoseAt = now
                switch demand {
                case .none: request = .joints
                case .lying: request = .lying
                case .nearPin: request = .nearPin(anchor: state.pinAnchor(in: record, at: now))
                case .rescuer: request = .rescuer
                }
            }
            return FrameJob(
                record: record,
                locate: locate,
                locateCarries: state.pendingLocateCarries,
                sendUplink: state.uplink.shouldSend(at: now),
                pose: request
            )
        }
        guard let job else { return false }

        var sent = false
        if !job.locate.isEmpty || job.sendUplink, let jpeg = await encode(frame, Self.jpegRotation) {
            // Encoding took time. The engine may have closed a gate, or tracking may have broken,
            // and each path checks its own gate again here.
            if !job.locate.isEmpty,
               // Taken under the lock a world reset empties the ledger with, so a reset after this voids the answer too.
               let request = state.withLock({ state -> (id: UInt64, materials: Set<Material>)? in
                   let materials = job.locate.filter { state.mayLocate($0) }
                   guard !materials.isEmpty, state.ledger.entry(for: frame.id) != nil else { return nil }
                   return (objects.beginRequest(for: materials), materials)
               }) {
                let frozen = FrozenFrame(jpeg: jpeg, record: job.record, rotation: Self.jpegRotation)
                let carries = job.locateCarries
                // Takes seconds, so it must not hold up the frame pump.
                Task.detached { [objects] in
                    await objects.locate(frozen, materials: request.materials, carries: carries, requestID: request.id)
                }
            }
            if job.sendUplink, state.withLock({ $0.uplink.isOpen && $0.ledger.entry(for: frame.id) != nil }) {
                uplinkContinuation.yield(UplinkFrame(frameID: frame.id, jpeg: jpeg, capturedAt: job.record.timestamp))
                sent = true
            }
        }

        if job.pose == .rescuer {
            let sample = await pose.rescuer(frame, record: job.record)
            coach(sample, record: job.record)
        } else if let request = job.pose {
            await pose.process(frame, record: job.record, request: request)
            if request == .lying { lockGhost(after: job.record) }
        }
        return sent
    }
}
