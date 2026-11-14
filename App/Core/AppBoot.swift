import AVFoundation
import Foundation
import RescueAudio
import RescueCore
import RescueLive
import RescueVision

/// Keeps counting while the phone sleeps, so a timeout is never late by the length of a nap.
enum MonotonicClock {
    @Sendable static func now() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }
}

/// Loads the shipped clinical files, refusing anything the engine could not run safely.
enum ProtocolLoader {
    /// Core only. `loadMerged` is what the app runs.
    static func load(from bundle: Bundle) -> ProtocolBundle? {
        guard
            let protocolURL = bundle.url(forResource: "adult_arrest.v1", withExtension: "json", subdirectory: "clinical"),
            let phrasesURL = bundle.url(forResource: "phrases.v1", withExtension: "json", subdirectory: "clinical"),
            let protocolData = try? Data(contentsOf: protocolURL),
            let phrasesData = try? Data(contentsOf: phrasesURL)
        else { return nil }
        return parse(protocolData: protocolData, phrasesData: phrasesData)
    }

    static func parse(protocolData: Data, phrasesData: Data) -> ProtocolBundle? {
        guard let loaded = try? ProtocolBundle(protocolData: protocolData, phrasesData: phrasesData),
              BundleValidator.isRunnable(loaded)
        else { return nil }
        return loaded
    }

    /// Core, then each module in manifest order, then the pack. Only a bad core stops the app.
    static func loadMerged(from bundle: Bundle) -> ProtocolBundle? {
        guard let core = load(from: bundle) else { return nil }
        let modules = ScenarioModule.manifest.map { id in
            ModuleSource(id: id, data: data(named: id, subdirectory: "clinical/modules", in: bundle))
        }
        return core.merging(modules: modules, pack: data(named: KnowledgePack.id, subdirectory: "clinical", in: bundle))
    }

    private static func data(named name: String, subdirectory: String, in bundle: Bundle) -> Data? {
        bundle.url(forResource: name, withExtension: "json", subdirectory: subdirectory)
            .flatMap { try? Data(contentsOf: $0) }
    }
}

@MainActor
enum AppBoot {
    case ready(AppCoordinator)
    case protocolUnavailable
    /// The unit tests are hosted in this app, and must not start real audio or AR behind it.
    case underTest

    static func make(bundle: Bundle = .main) -> AppBoot {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return .underTest }
        guard let protocolBundle = ProtocolLoader.loadMerged(from: bundle) else { return .protocolUnavailable }

        let key = apiKey(in: bundle)
        let gate = UplinkGate()
        let locator: any ObjectLocating = key.map { GeminiObjectLocator(locator: GeminiLocator(apiKey: $0), gate: gate) }
            ?? UnavailableLocator()

        var texts = Dictionary(protocolBundle.phrases.phrases.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        texts[AppCoordinator.seededPhraseID] = AppCoordinator.seededLine
        texts[AppCoordinator.seededAwakePhraseID] = AppCoordinator.seededAwakeLine

        #if DEBUG
        // The Simulator has no ARKit, so this stages a camera to look at every AR mark there.
        let staged = StagedLaunch.stagesCamera
        let vision: any VisionPort = staged ? StagedVision() : VisionSession(locator: locator)
        let cameraAllowed: @MainActor () -> Bool
        if staged { cameraAllowed = { true } } else { cameraAllowed = { Permissions.cameraGranted } }
        #else
        let vision: any VisionPort = VisionSession(locator: locator)
        let cameraAllowed: @MainActor () -> Bool = { Permissions.cameraGranted }
        #endif

        return .ready(AppCoordinator(
            // With an AI to look and listen, the rescue opens on assess. With none it opens on the
            // arrest path's first question, since nothing could do the assessing.
            engine: ProtocolEngine(bundle: key == nil ? protocolBundle : protocolBundle.startingWithAssessment()),
            audio: RescueAudioController(phraseTexts: texts, bundle: bundle),
            vision: vision,
            gate: gate,
            canLocate: key != nil,
            makeLive: liveFactory(
                key: key,
                contracts: toolContracts(in: bundle),
                pack: protocolBundle.knowledgePack,
                appLines: protocolBundle.awakeLines,
                voiceName: voiceName(in: bundle)
            ),
            cameraAllowed: cameraAllowed
        ))
    }

    static func apiKey(in bundle: Bundle) -> APIKey? {
        apiKey(plistValue: bundle.object(forInfoDictionaryKey: "GeminiAPIKey") as? String)
    }

    static func apiKey(plistValue raw: String?) -> APIKey? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        // An unset build setting can arrive unexpanded.
        guard !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return APIKey(value)
    }

    /// The prebuilt voice the clips were rendered in, so the AI and the app's own lines sound like one
    /// person. Nil leaves Live on its default voice.
    static func voiceName(in bundle: Bundle) -> String? {
        voiceName(plistValue: bundle.object(forInfoDictionaryKey: "GeminiVoice") as? String)
    }

    static func voiceName(plistValue raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        // An unset build setting can arrive unexpanded.
        guard !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    static func toolContracts(in bundle: Bundle) -> [LiveMode: Data] {
        let files: [LiveMode: String] = [.arrest: "tools.v1", .awake: "tools.awake.v1"]
        return files.compactMapValues { name in
            bundle.url(forResource: name, withExtension: "json", subdirectory: "contracts")
                .flatMap { try? Data(contentsOf: $0) }
        }
    }

    /// A new session for each rescue and each mode, because a kept resumption handle carries the old
    /// context. A mode whose contract didn't ship stays offline, and the other still runs.
    static func liveFactory(
        key: APIKey?,
        contracts: [LiveMode: Data],
        pack: KnowledgePack?,
        appLines: [String] = [],
        voiceName: String? = nil,
        clock: @escaping @Sendable () -> TimeInterval = MonotonicClock.now,
        makeTransport: @escaping @MainActor (GeminiLiveConfiguration) -> any RealtimeTransport = { GeminiLiveTransport(configuration: $0) }
    ) -> @MainActor (LiveMode) -> LiveStack? {
        guard let key else { return { _ in nil } }
        let awakePrompt = SystemPrompt.awake(pack: pack, appLines: appLines)
        return { mode in
            guard let contract = contracts[mode] else { return nil }
            var configuration = GeminiLiveConfiguration(apiKey: key, toolContract: contract)
            configuration.systemInstruction = mode == .awake ? awakePrompt : SystemPrompt.text
            // Both modes, so a swap mid-rescue doesn't change who is talking.
            configuration.voiceName = voiceName
            return LiveStack(
                session: LiveSession(transport: makeTransport(configuration), clock: clock, mode: mode),
                auditor: Auditor(apiKey: key)
            )
        }
    }
}

// The coordinator's view of the packages. Both already fit, and the tests swap in fakes.

protocol AudioPort: AnyObject, Sendable {
    func start()
    func setPolicy(_ policy: RuntimePolicy)
    func setMetronome(on: Bool)
    func play(phraseID: String)
    func enqueueModelAudio(_ data: Data)
    func flushModelAudio()
    var modelAudioPending: Bool { get }
    func dropQueuedPhrases(keeping: [String])
    func cutPhrases()
    func modelTurnEnded()
    func pause(seconds: TimeInterval)
    func resume()
    func speak(text: String)
    var onUplinkPCM: (@Sendable (Data) -> Void)? { get set }
    var onSpeechStarted: (@Sendable () -> Void)? { get set }
    var onSpeechEnded: (@Sendable () -> Void)? { get set }
    var onPhraseFinished: (@Sendable (String) -> Void)? { get set }
    var onCallChanged: (@Sendable (Bool) -> Void)? { get set }
    var onStatus: (@Sendable (AudioStatus) -> Void)? { get set }
}

extension RescueAudioController: AudioPort {}

protocol VisionPort: AnyObject, Sendable {
    var isARSupported: Bool { get }
    var status: VisionStatus { get }
    var aedStatus: AEDStatus { get }
    var keypointAge: TimeInterval? { get }
    var lastNoTargetReason: NoTargetReason? { get }
    var uplinkFrames: AsyncStream<UplinkFrame> { get }
    func start()
    func stop()
    func apply(_ effect: RescueEffect)
    func beginFrameBurst()
    func overlay() -> VisionOverlay
    func placeInjuryPin(atViewPoint point: CGPoint) async -> InjuryPinResult
    /// Frozen frames to the locator only. Vision drops it unless the step's policy allows it.
    func requestLocate(_ materials: Set<Material>)
    func locateStatus(_ material: Material) -> AEDStatus
    func sightings(of material: Material) -> Int
    /// The chest zone for the first seconds of compressions. After the entry's effects, since every
    /// overlay change ends it.
    func beginHandsGuide(seconds: TimeInterval)
    var showsHandsGuide: Bool { get }
    /// The ghost rescuer pushes on the metronome's beat, so it follows the metronome on and off.
    func setGhostBeat(on: Bool)
    /// An imaginary patient on the floor at a point in view, for practice with no one lying down.
    func placePracticePatient(atViewPoint point: CGPoint?) async -> Bool
    func clearPracticePatient()
    /// How the person compressing compares with the ghost, nil with nothing to say.
    func compressionFeedback() -> CompressionFeedback?
    /// The ghost is on screen pushing on the beat.
    var showsGhost: Bool { get }
}

extension VisionPort {
    // A port with no camera has no ghost to draw.
    func setGhostBeat(on: Bool) {}
    func placePracticePatient(atViewPoint point: CGPoint?) async -> Bool { false }
    func clearPracticePatient() {}
    func compressionFeedback() -> CompressionFeedback? { nil }
    var showsGhost: Bool { false }
}

extension VisionSession: VisionPort {}

/// Bridges RescueVision to the cloud locator. The engine can close a gate while a frame waits here,
/// so the policy is checked again at the last moment before the image leaves the phone.
struct GeminiObjectLocator: ObjectLocating {
    let locator: GeminiLocator
    let gate: UplinkGate

    /// The AED's own scan, behind the frame uplink as it always has been.
    func locate(jpeg: Data, label: String) async -> NormalizedBox? {
        guard gate.framesOpen, let box = await locator.locate(jpeg: jpeg, label: label) else { return nil }
        return Self.normalized(box)
    }

    /// A step's materials in one request, behind the locate gate, which a limb step opens without
    /// opening the uplink. A towel, pillow or gloves never goes on the uplink alone, so none is looked
    /// for on the arrest path. The AED alone still goes the way it always has.
    func locate(jpeg: Data, materials: [Material]) async -> [Material: NormalizedBox] {
        let allowed = materials.filter { $0 == .aed || gate.materialsOpen }
        if allowed == [.aed] {
            return await locate(jpeg: jpeg, label: Material.aed.rawValue).map { [.aed: $0] } ?? [:]
        }
        guard gate.locateOpen, !allowed.isEmpty else { return [:] }
        var boxes: [Material: NormalizedBox] = [:]
        // Most prominent first, so the first box for each material is the one kept.
        for box in await locator.locate(jpeg: jpeg, materials: allowed) {
            guard let material = box.material, boxes[material] == nil, let normalized = Self.normalized(box) else { continue }
            boxes[material] = normalized
        }
        return boxes
    }

    private static func normalized(_ box: LocatedBox) -> NormalizedBox? {
        NormalizedBox(minX: box.minX, minY: box.minY, maxX: box.maxX, maxY: box.maxY)
    }
}

struct UnavailableLocator: ObjectLocating {
    func locate(jpeg: Data, label: String) async -> NormalizedBox? { nil }
}

enum Permissions {
    static var cameraGranted: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    /// Onboarding only. Nothing in the rescue flow may call this.
    static func requestCameraAndMic() async {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        _ = await AVAudioApplication.requestRecordPermission()
    }
}
