import CoreGraphics
import CoreVideo
import Foundation
import RescueCore
import Synchronization

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
        var wantsRunning = false
        var arActive = false
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
                now: now
            )
        }

        func needsPixels(at now: TimeInterval, holdsLimb: Bool) -> Bool {
            poseDemand(at: now, holdsLimb: holdsLimb) != .none || uplink.isOpen || !pendingLocate.isEmpty
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
        clock: @escaping @Sendable () -> TimeInterval,
        runsPump: Bool,
        encode: (@Sendable (CapturedFrame, CaptureRotation) async -> Data?)? = nil
    ) {
        self.driver = driver
        self.clock = clock
        let encoder = FrameEncoder()
        self.encode = encode ?? { await encoder.encode($0, rotation: $1) }
        pose = PoseWorker(detect: detect)
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

    /// The overlay for this instant, cheap enough to call every display frame.
    public func overlay() -> VisionOverlay {
        let now = clock()
        let (latest, latestPose) = pose.snapshot
        let aedPoint = objects.worldPoint(.aed)
        let carriedPoint = objects.carriedPoint(.aed)
        let callouts = objects.callouts()
        return state.withLock { state in
            VisionOverlay.compose(
                target: state.overlayTarget,
                ring: state.ring.output(latest: latest, at: now),
                camera: state.ledger.latest,
                mapping: state.mapping,
                aedPoint: aedPoint,
                carriedAED: state.showsCarriedAED ? carriedPoint : nil,
                injuryPin: state.injuryPin,
                pose: latestPose,
                items: callouts.filter { state.wanted.contains($0.key) },
                handsGuide: state.showsHandsGuide(at: now),
                now: now
            )
        }
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
        }
        objects.clear()
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
        imageToView: CGAffineTransform?
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
        let frame = CapturedFrame(id: wanted, pixels: pixels)
        framesContinuation.yield(frame)
        return frame
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
            let rate = demand.framesPerSecond(load: state.load, now: now)
            var request: PoseRequest?
            if rate > 0, now - state.lastPoseAt >= 1 / rate {
                state.lastPoseAt = now
                switch demand {
                case .none: break
                case .lying: request = .lying
                case .nearPin: request = .nearPin(anchor: state.pinAnchor(in: record, at: now))
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

        if let request = job.pose {
            await pose.process(frame, record: job.record, request: request)
        }
        return sent
    }
}
