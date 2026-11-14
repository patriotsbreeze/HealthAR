#if os(iOS)
import AVFoundation
import CallKit
import RescueCore
import Synchronization
import UIKit

/// The single audio graph: metronome, local phrases, Read Aloud, model audio, and mic capture.
///
/// Every method returns at once and is safe from any thread. Callbacks arrive on a private serial
/// queue, never the render thread and never the main thread.
public final class RescueAudioController: @unchecked Sendable {
    private struct Handlers: Sendable {
        var onUplinkPCM: (@Sendable (Data) -> Void)?
        var onSpeechStarted: (@Sendable () -> Void)?
        var onSpeechEnded: (@Sendable () -> Void)?
        var onPhraseFinished: (@Sendable (String) -> Void)?
        var onCallChanged: (@Sendable (Bool) -> Void)?
        var onStatus: (@Sendable (AudioStatus) -> Void)?
    }

    /// 16 kHz, 16-bit little-endian mono, in chunks of 20 ms, only while speech is detected.
    public var onUplinkPCM: (@Sendable (Data) -> Void)? {
        get { handlers.withLock { $0.onUplinkPCM } }
        set { handlers.withLock { $0.onUplinkPCM = newValue } }
    }
    /// Barge-in: the app can flush model audio here.
    public var onSpeechStarted: (@Sendable () -> Void)? {
        get { handlers.withLock { $0.onSpeechStarted } }
        set { handlers.withLock { $0.onSpeechStarted = newValue } }
    }
    public var onSpeechEnded: (@Sendable () -> Void)? {
        get { handlers.withLock { $0.onSpeechEnded } }
        set { handlers.withLock { $0.onSpeechEnded = newValue } }
    }
    /// The phrase's last sample has been rendered. A phrase that failed isn't reported here.
    public var onPhraseFinished: (@Sendable (String) -> Void)? {
        get { handlers.withLock { $0.onPhraseFinished } }
        set { handlers.withLock { $0.onPhraseFinished = newValue } }
    }
    /// Fires once at start with the initial state, then whenever it changes.
    public var onCallChanged: (@Sendable (Bool) -> Void)? {
        get { handlers.withLock { $0.onCallChanged } }
        set { handlers.withLock { $0.onCallChanged = newValue } }
    }
    public var onStatus: (@Sendable (AudioStatus) -> Void)? {
        get { handlers.withLock { $0.onStatus } }
        set { handlers.withLock { $0.onStatus = newValue } }
    }

    private static let micRetries = 2
    private static let micRetryDelay = 3.0
    private static let maxEngineRestarts = 3
    private static let engineSettleTime = 5.0
    private static let readAloudID = "read_aloud"

    private let handlers = Mutex(Handlers())
    let core = RenderCore()
    let gate = SpeechGate(sampleRate: RenderCore.voiceSampleRate)
    private let modelGeneration = Atomic<Int>(0)
    private let phraseTexts: [String: String]
    private let bundle: Bundle
    private let queue = DispatchQueue(label: "rescue.audio", qos: .userInteractive)

    // Seams for tests. The controller never prompts for the mic, since that happens at onboarding.
    var micPermissionGranted: @Sendable () -> Bool = { AVAudioApplication.shared.recordPermission == .granted }
    var enableVoiceProcessing: @Sendable (AVAudioInputNode) throws -> Void = { try $0.setVoiceProcessingEnabled(true) }

    // Everything below is confined to `queue`.
    private var hasStarted = false
    private var engine: AVAudioEngine?
    private var activeMode: AudioMode?
    private var desiredMode = AudioMode.full
    private var policyModelOpen = false
    private var policyMicUplink = false
    private var modelWaitsForPhrases = false
    private var uplinkAllowed = false
    private var callActive = false
    private var micFailed = false
    private var micRetriesLeft = RescueAudioController.micRetries
    private var lastMicProblem: String?
    private var watchdog = OutputWatchdog()
    private var outputLostReported = false
    private var pauseToken = 0
    private var rebuildToken = 0
    private var clips: [String: [Float]] = [:]
    private var phraseLane: VoiceLane
    private var readAloudLane: VoiceLane
    private var modelDecoder = PCM16Decoder()
    private var vad = ClientVAD()
    private var micResampler: MicResampler?
    private var callWatcher: CallWatcher?
    private var phraseSpeech: SpeechRenderer?
    private var readAloudSpeech: SpeechRenderer?
    private var timer: (any DispatchSourceTimer)?
    private var observers: [any NSObjectProtocol] = []
    private var engineObserver: (any NSObjectProtocol)?
    private var micFormat: AVAudioFormat?
    private var builtRouteKey = ""
    private var engineRestarts = 0
    private var lastEngineRestart = DispatchTime.now()

    /// `phraseTexts` maps each phrase ID to its text, which is spoken when `<phraseID>.wav` is missing.
    public init(phraseTexts: [String: String], bundle: Bundle = .main) {
        self.phraseTexts = phraseTexts
        self.bundle = bundle
        phraseLane = VoiceLane(ring: core.phraseRing)
        readAloudLane = VoiceLane(ring: core.readAloudRing)
    }

    deinit {
        timer?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        // The render callbacks stop when this returns, so the memory they use can go.
        engine?.stop()
        engine = nil
        core.deallocate()
    }

    // MARK: - Public surface

    public func start() {
        queue.async { self.startIfNeeded() }
    }

    public func setMode(_ mode: AudioMode) {
        queue.async {
            self.desiredMode = mode
            self.reconcile()
        }
    }

    public func setPolicy(_ policy: RuntimePolicy) {
        // Closing can't wait in line behind audio that is already queued.
        if !policy.modelSpeechOpen { closeGateNow() }
        queue.async {
            self.policyModelOpen = policy.modelSpeechOpen
            self.policyMicUplink = policy.micUplink
            self.modelWaitsForPhrases = policy.modelAudioWaitsForPhrases
            self.desiredMode = policy.audioMode
            self.reconcile()
        }
    }

    /// Only the caller turns the metronome on or off. Nothing in this class changes it.
    public func setMetronome(on: Bool) {
        core.setMetronome(on: on)
        start()
    }

    /// Queues a local phrase. It takes over from model audio at once.
    public func play(phraseID: String) {
        flushModelAudio()
        queue.async {
            self.startIfNeeded()
            if let clip = self.clips[phraseID] {
                self.phraseLane.enqueueClip(id: phraseID, samples: clip)
            } else if let text = self.phraseTexts[phraseID] {
                self.report(.phraseUsingSpeech(id: phraseID))
                self.phraseLane.enqueueText(id: phraseID, text: text)
            } else {
                self.report(.phraseFailed(id: phraseID))
                return
            }
            // Catches model audio pushed from another thread since the flush above. From here the
            // busy lane keeps more from being pushed.
            self.core.modelRing.flush()
            self.pumpLanes()
        }
    }

    /// Forgets phrases that haven't started, except `keeping`. The one playing finishes.
    public func dropQueuedPhrases(keeping: [String]) {
        queue.async { self.phraseLane.dropQueued(keeping: Set(keeping)) }
    }

    /// Silences local phrases at once, and forgets the ones queued.
    public func cutPhrases() {
        queue.async {
            if self.phraseLane.cut() { self.phraseSpeech?.cancel() }
        }
    }

    /// Takes 24 kHz, 16-bit little-endian mono.
    public func enqueueModelAudio(_ data: Data) {
        guard gate.isOpen else { return }
        let generation = modelGeneration.load(ordering: .acquiring)
        queue.async {
            guard generation == self.modelGeneration.load(ordering: .acquiring) else { return }
            self.pushModelAudio(data)
        }
    }

    public func flushModelAudio() {
        modelGeneration.add(1, ordering: .acquiringAndReleasing)
        core.modelRing.flush()
        queue.async {
            // A push that had already passed its generation check lands before this one.
            self.core.modelRing.flush()
            self.modelDecoder.reset()
        }
    }

    /// Call on the model's turn-complete or interrupted message. Without it, the runaway guard
    /// treats everything as one long turn and silences the model after 20 s of audio in total.
    public func modelTurnEnded() {
        queue.async {
            self.gate.endTurn()
            self.modelDecoder.reset()
        }
    }

    /// Mutes output, keeping the beat phase and holding queued phrases, for at most `seconds`.
    public func pause(seconds: TimeInterval) {
        core.setMuted(true)
        queue.async {
            self.pauseToken += 1
            let token = self.pauseToken
            self.queue.asyncAfter(deadline: .now() + max(0, seconds)) { [weak self] in
                guard let self, self.pauseToken == token else { return }
                self.core.setMuted(false)
            }
        }
    }

    public func resume() {
        core.setMuted(false)
        queue.async { self.pauseToken += 1 }
    }

    /// Reads text aloud with on-device speech. Local phrases interrupt it, and it continues after.
    public func speak(text: String) {
        guard !text.isEmpty else { return }
        flushModelAudio()
        queue.async {
            self.startIfNeeded()
            self.readAloudLane.enqueueText(id: Self.readAloudID, text: text)
            self.core.modelRing.flush()
            self.pumpLanes()
        }
    }

    // MARK: - Startup

    private func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true

        let controllerQueue = queue
        phraseSpeech = SpeechRenderer(queue: controllerQueue) { [weak self] in self?.handlePhraseSpeech($0) }
        readAloudSpeech = SpeechRenderer(queue: controllerQueue) { [weak self] in self?.handleReadAloudSpeech($0) }
        observeSession()

        let watcher = CallWatcher(queue: controllerQueue) { [weak self] in self?.refreshCallState() }
        callWatcher = watcher
        callActive = watcher.isCallActive
        handlers.withLock { $0.onCallChanged }?(callActive)

        // Sound first: decoding clips must not delay the metronome.
        rebuild()
        decodeClips()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func decodeClips() {
        var anyMissing = false
        for id in phraseTexts.keys {
            if let url = bundle.url(forResource: id, withExtension: "wav"), let samples = try? decodeClip(at: url) {
                clips[id] = samples
            } else {
                anyMissing = true
            }
        }
        if anyMissing { phraseSpeech?.warmUp() }
    }

    // MARK: - The graph

    private func targetMode() -> AudioMode {
        guard desiredMode == .full, !callActive, !micFailed, micPermissionGranted() else { return .playbackOnly }
        return .full
    }

    private func reconcile() {
        guard hasStarted else { return }
        if targetMode() != activeMode {
            rebuild()
        } else {
            applyPolicy()
        }
    }

    /// Always a new engine: once `inputNode` has been touched, an engine can't run under `playback`.
    private func rebuild(stopOldEngine: Bool = true) {
        tearDownEngine(stop: stopOldEngine)
        activeMode = nil

        if desiredMode == .full, !callActive, !micPermissionGranted() {
            reportMicProblem("Microphone permission not granted")
        }
        if targetMode() == .full {
            do {
                try startEngine(mode: .full)
                activeMode = .full
                lastMicProblem = nil
            } catch {
                tearDownEngine(stop: true)
                micFailed = true
                reportMicProblem("\(error)")
                scheduleMicRetry()
            }
        }
        if activeMode == nil {
            do {
                try startEngine(mode: .playbackOnly)
                activeMode = .playbackOnly
            } catch {
                tearDownEngine(stop: true)
                // The output check tries again every second.
                reportOutputLost("\(error)")
            }
        }
        builtRouteKey = currentRouteKey()
        // From here, since starting voice processing can take over a second, which isn't the output failing.
        watchdog.engineStarted(at: Self.uptime())
        applyPolicy()
    }

    private func tearDownEngine(stop: Bool) {
        if let engineObserver {
            NotificationCenter.default.removeObserver(engineObserver)
            self.engineObserver = nil
        }
        if stop { engine?.stop() }
        engine = nil
        micResampler = nil
        core.micRing.flush()
        deliver(vad.reset())
    }

    private func startEngine(mode: AudioMode) throws {
        let session = AVAudioSession.sharedInstance()
        switch mode {
        case .full:
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
        case .playbackOnly:
            // Mixable, so this can't interrupt another app that may be hosting a call.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try? session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)

        let engine = AVAudioEngine()
        if mode == .full { try attachMic(to: engine, session: session) }
        guard core.attachOutputs(to: engine) else { throw AudioGraphError.noOutputFormat }
        self.engine = engine
        // Before starting, since voice processing can stop the engine right after it starts.
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.handleEngineConfigurationChange() }
        }
        engine.prepare()
        try engine.start()
    }

    // Formats are checked before connecting, since a bad one raises an exception Swift can't catch.
    private func attachMic(to engine: AVAudioEngine, session: AVAudioSession) throws {
        guard session.isInputAvailable else { throw AudioGraphError.noInput }
        let input = engine.inputNode
        try enableVoiceProcessing(input)
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)

        let format = input.outputFormat(forBus: 0)
        guard
            format.sampleRate > 0, format.channelCount > 0,
            format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
            let resampler = MicResampler(inputSampleRate: format.sampleRate)
        else { throw AudioGraphError.unusableInputFormat("\(format)") }

        let sink = core.makeMicSink()
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        micResampler = resampler
        micFormat = format
    }

    // MARK: - The 20 ms tick

    private func tick() {
        pumpLanes()
        phraseSpeech?.checkTimeouts()
        readAloudSpeech?.checkTimeouts()
        drainMic()
        checkOutput()
    }

    private func pumpLanes() {
        let phrases = phraseLane.pump()
        if !phrases.finished.isEmpty, let onFinished = handlers.withLock({ $0.onPhraseFinished }) {
            phrases.finished.forEach(onFinished)
        }
        if let text = phrases.startSynthesis { phraseSpeech?.begin(text: text) }
        if let text = readAloudLane.pump().startSynthesis { readAloudSpeech?.begin(text: text) }
        core.setModelHeld(modelWaitsForPhrases && phraseLane.isBusy)
    }

    private func drainMic() {
        guard let micResampler else { return }
        let samples = micResampler.drain(core.micRing)
        guard uplinkAllowed, !samples.isEmpty else { return }
        deliver(vad.process(samples))
    }

    private func deliver(_ outputs: [ClientVAD.Output]) {
        guard !outputs.isEmpty else { return }
        let current = handlers.withLock { $0 }
        for output in outputs {
            switch output {
            case .speechStarted: current.onSpeechStarted?()
            case let .audio(samples): current.onUplinkPCM?(PCM16.data(from: samples))
            case .speechEnded: current.onSpeechEnded?()
            }
        }
    }

    private func checkOutput() {
        switch watchdog.check(renderCount: core.renderCallCount, mode: activeMode, at: Self.uptime()) {
        case .nothingToDo:
            break
        case .confirmed:
            outputLostReported = false
            if let activeMode { report(.running(activeMode)) }
        case let .rebuild(giveUpOnMic):
            reportOutputLost("No audio callbacks")
            if giveUpOnMic {
                micFailed = true
                reportMicProblem("Voice processing gave no audio")
                scheduleMicRetry()
            }
            rebuild()
        }
    }

    private static func uptime() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    // MARK: - Speech

    private func handlePhraseSpeech(_ event: SpeechRenderer.Event) {
        switch event {
        case let .samples(samples):
            phraseLane.appendToHead(samples)
        case .finished:
            phraseLane.completeHead()
        case .failed:
            if let id = phraseLane.failHead() { report(.phraseFailed(id: id)) }
        }
        pumpLanes()
    }

    private func handleReadAloudSpeech(_ event: SpeechRenderer.Event) {
        switch event {
        case let .samples(samples):
            readAloudLane.appendToHead(samples)
        case .finished:
            readAloudLane.completeHead()
        case .failed:
            if readAloudLane.failHead() != nil { report(.readAloudFailed) }
        }
        pumpLanes()
    }

    // MARK: - Model audio

    private func pushModelAudio(_ data: Data) {
        let samples = modelDecoder.decode(data)
        // A local phrase always wins. Holding this audio instead would replay stale speech after it,
        // except where the policy says someone is waiting on it.
        guard modelWaitsForPhrases || !phraseLane.isBusy, !readAloudLane.isBusy else { return }
        switch gate.admit(sampleCount: samples.count) {
        case .closed:
            break
        case let .runaway(justTripped):
            if justTripped { report(.runawayTurnStopped) }
        case let .pass(sampleCount):
            samples.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                core.modelRing.push(base, count: sampleCount)
            }
        }
    }

    private func closeGateNow() {
        gate.setOpen(false)
        flushModelAudio()
    }

    /// Playback-only mode has no mic, so the model hears nothing, and it may be during a call.
    private func applyPolicy() {
        let modelAllowed = policyModelOpen && activeMode == .full
        gate.setOpen(modelAllowed)
        if !modelAllowed { core.modelRing.flush() }

        uplinkAllowed = policyMicUplink && activeMode == .full
        if !uplinkAllowed { deliver(vad.reset()) }
    }

    // MARK: - System events

    private func refreshCallState() {
        guard let active = callWatcher?.isCallActive, active != callActive else { return }
        callActive = active
        handlers.withLock { $0.onCallChanged }?(active)
        if active {
            closeGateNow()
        } else {
            allowMicRetries()
        }
        reconcile()
    }

    private func observeSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        let controllerQueue = queue
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
                guard let self else { return }
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let type = raw.flatMap(AVAudioSession.InterruptionType.init)
                controllerQueue.async { self.handleInterruption(type) }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] note in
                guard let self else { return }
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init)
                controllerQueue.async { self.handleRouteChange(reason) }
            },
            // The input can refuse to start while backgrounded, as after a call on this phone, and
            // the retries can run out before the person comes back.
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                controllerQueue.async {
                    self.allowMicRetries()
                    self.reconcile()
                }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification, object: session, queue: nil) { [weak self] _ in
                guard let self else { return }
                controllerQueue.async { self.reportOutputLost("Media services lost") }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
                guard let self else { return }
                controllerQueue.async {
                    self.allowMicRetries()
                    // The old engine died with the media server, so there's nothing to stop.
                    self.rebuild(stopOldEngine: false)
                }
            },
        ]
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        // Call events can be missed, and a call nearly always comes with an interruption.
        refreshCallState()
        switch type {
        case .began:
            // The output check retries from here, so a missing "ended" can't leave it silent.
            watchdog.outputInterrupted()
            reportOutputLost("Interrupted")
        case .ended:
            allowMicRetries()
            rebuild()
        default:
            break
        }
    }

    private func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason?) {
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .wakeFromSleep, .noSuitableRouteForCategory:
            // Setting up the session changes the route too. Rebuilding on that would loop.
            if currentRouteKey() != builtRouteKey { scheduleRebuild() }
        default:
            break
        }
    }

    /// Voice processing can stop the engine just after it starts, while the hardware settles, and
    /// a new engine would do the same. So restart this one, and only give up if it keeps stopping.
    private func handleEngineConfigurationChange() {
        guard let engine, !engine.isRunning else { return }
        if DispatchTime.now() > lastEngineRestart + Self.engineSettleTime { engineRestarts = 0 }
        lastEngineRestart = .now()
        engineRestarts += 1
        // In playback mode a failure here is left to the output check, which rebuilds once a second.
        if engineRestarts <= Self.maxEngineRestarts {
            if canRestart(engine), (try? engine.start()) != nil { return }
            if activeMode == .full { rebuild() }
        } else if activeMode == .full {
            engineRestarts = 0
            micFailed = true
            reportMicProblem("Voice processing keeps stopping")
            scheduleMicRetry()
            rebuild()
        }
    }

    // The mic connection holds the old hardware format, and starting with a stale one can raise an
    // exception. Playback mode must never touch `inputNode`.
    private func canRestart(_ engine: AVAudioEngine) -> Bool {
        activeMode != .full || engine.inputNode.outputFormat(forBus: 0) == micFormat
    }

    private func currentRouteKey() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        return (route.inputs + route.outputs).map(\.uid).joined(separator: ",")
    }

    /// Route changes tend to arrive in bursts, and each rebuild briefly stops the beat.
    private func scheduleRebuild() {
        rebuildToken += 1
        let token = rebuildToken
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.rebuildToken == token else { return }
            self.allowMicRetries()
            self.rebuild()
        }
    }

    private func allowMicRetries() {
        micFailed = false
        micRetriesLeft = Self.micRetries
    }

    /// The mic can fail right after a call while the system lets go of it. Retries are limited
    /// because each one briefly stops the beat.
    private func scheduleMicRetry() {
        guard micRetriesLeft > 0 else { return }
        micRetriesLeft -= 1
        queue.asyncAfter(deadline: .now() + Self.micRetryDelay) { [weak self] in
            guard let self, self.micFailed else { return }
            self.micFailed = false
            self.reconcile()
        }
    }

    // MARK: - Status

    private func report(_ status: AudioStatus) {
        handlers.withLock { $0.onStatus }?(status)
    }

    private func reportOutputLost(_ reason: String) {
        guard !outputLostReported else { return }
        outputLostReported = true
        report(.outputLost(reason: reason))
    }

    private func reportMicProblem(_ reason: String) {
        guard lastMicProblem != reason else { return }
        lastMicProblem = reason
        report(.micUnavailable(reason: reason))
    }
}

private enum AudioGraphError: Error {
    case noInput
    case unusableInputFormat(String)
    case noOutputFormat
}

private final class CallWatcher: NSObject, CXCallObserverDelegate, @unchecked Sendable {
    private let observer = CXCallObserver()
    private let onChange: @Sendable () -> Void

    init(queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        super.init()
        observer.setDelegate(self, queue: queue)
    }

    var isCallActive: Bool {
        observer.calls.contains { !$0.hasEnded }
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        onChange()
    }
}
#endif
