import Foundation
@testable import HealthAISim
import RescueAudio
import RescueCore
import RescueLive
@testable import RescueVision
import Synchronization
import Testing

final class TestClock: Sendable {
    private let value = Mutex<TimeInterval>(1000)
    var now: TimeInterval { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
    var reader: @Sendable () -> TimeInterval { { self.now } }
}

final class FakeAudio: AudioPort, @unchecked Sendable {
    enum Call: Equatable {
        case start
        case policy(RuntimePolicy)
        case metronome(Bool)
        case play(String)
        case modelAudio(Data)
        case flush
        case dropQueued([String])
        case cut
        case turnEnded
        case pause(TimeInterval)
        case resume
        case speak(String)
    }

    private let recorded = Mutex<[Call]>([])
    var calls: [Call] { recorded.withLock { $0 } }
    private func note(_ call: Call) { recorded.withLock { $0.append(call) } }
    func clearCalls() { recorded.withLock { $0 = [] } }

    var played: [String] {
        calls.compactMap { if case let .play(id) = $0 { id } else { nil } }
    }
    /// What's still to be said, head first, as the real lane would have it: a drop spares the phrase
    /// that has started, which here is the head, and a cut takes everything. `played` is only what was
    /// ever enqueued, so it can't say whether a phrase survived a tap.
    var lane: [String] {
        var lane: [String] = []
        for call in calls {
            switch call {
            case let .play(id): lane.append(id)
            case let .dropQueued(keeping): lane = lane.prefix(1) + lane.dropFirst().filter(keeping.contains)
            case .cut: lane = []
            default: break
            }
        }
        return lane
    }
    var lastPolicy: RuntimePolicy? {
        calls.last { if case .policy = $0 { true } else { false } }.flatMap { if case let .policy(p) = $0 { p } else { nil } }
    }
    var metronome: [Bool] {
        calls.compactMap { if case let .metronome(on) = $0 { on } else { nil } }
    }

    func start() { note(.start) }
    func setPolicy(_ policy: RuntimePolicy) { note(.policy(policy)) }
    func setMetronome(on: Bool) { note(.metronome(on)) }
    func play(phraseID: String) { note(.play(phraseID)) }
    func enqueueModelAudio(_ data: Data) { note(.modelAudio(data)) }
    func flushModelAudio() { note(.flush) }
    func dropQueuedPhrases(keeping: [String]) { note(.dropQueued(keeping)) }
    func cutPhrases() { note(.cut) }
    func modelTurnEnded() { note(.turnEnded) }
    func pause(seconds: TimeInterval) { note(.pause(seconds)) }
    func resume() { note(.resume) }
    func speak(text: String) { note(.speak(text)) }

    var onUplinkPCM: (@Sendable (Data) -> Void)?
    var onSpeechStarted: (@Sendable () -> Void)?
    var onSpeechEnded: (@Sendable () -> Void)?
    var onPhraseFinished: (@Sendable (String) -> Void)?
    var onCallChanged: (@Sendable (Bool) -> Void)?
    var onStatus: (@Sendable (AudioStatus) -> Void)?
}

final class FakeVision: VisionPort, @unchecked Sendable {
    private struct State {
        var applied: [RescueEffect] = []
        var startCount = 0
        var bursts = 0
        var aedStatus = AEDStatus.idle
        var overlay = VisionOverlay.empty
        var pinResult = InjuryPinResult.placed
        var pinTaps: [CGPoint] = []
        var status: VisionStatus?
        var locateRequests: [Set<RescueCore.Material>] = []
        var locateStatus: [RescueCore.Material: AEDStatus] = [:]
        var sightings: [RescueCore.Material: Int] = [:]
        var handsGuides: [TimeInterval] = []
        var showsHandsGuide = false
        var ghostBeats: [Bool] = []
        var practicePlacements: [CGPoint?] = []
        var practicePlaces = true
        var practiceClears = 0
    }

    private let state = Mutex(State())
    let supported: Bool
    let uplinkFrames: AsyncStream<UplinkFrame>
    private let frames: AsyncStream<UplinkFrame>.Continuation
    private let nextFrame = Mutex<UInt64>(0)

    init(supported: Bool = false) {
        self.supported = supported
        (uplinkFrames, frames) = AsyncStream.makeStream()
    }

    var applied: [RescueEffect] { state.withLock { $0.applied } }
    var startCount: Int { state.withLock { $0.startCount } }
    var bursts: Int { state.withLock { $0.bursts } }
    var locateCount: Int { applied.filter { $0 == .locate(.aed) }.count }
    var pinTaps: [CGPoint] { state.withLock { $0.pinTaps } }
    func setAEDStatus(_ status: AEDStatus) { state.withLock { $0.aedStatus = status } }
    func setOverlay(_ overlay: VisionOverlay) { state.withLock { $0.overlay = overlay } }
    func setPinResult(_ result: InjuryPinResult) { state.withLock { $0.pinResult = result } }
    /// For AR that stops partway, as for heat.
    func setStatus(_ status: VisionStatus) { state.withLock { $0.status = status } }
    var locateRequests: [Set<RescueCore.Material>] { state.withLock { $0.locateRequests } }
    func setLocateStatus(_ status: AEDStatus, for material: RescueCore.Material, sightings: Int = 0) {
        state.withLock {
            $0.locateStatus[material] = status
            $0.sightings[material] = sightings
        }
    }
    /// Each window's length, in the order they opened.
    var handsGuides: [TimeInterval] { state.withLock { $0.handsGuides } }

    func emitFrame(_ jpeg: Data) {
        let id = nextFrame.withLock { $0 += 1; return $0 }
        frames.yield(UplinkFrame(frameID: id, jpeg: jpeg, capturedAt: 0))
    }

    var isARSupported: Bool { supported }
    var status: VisionStatus { state.withLock { $0.status } ?? (supported ? .running : .unsupported) }
    var aedStatus: AEDStatus { state.withLock { $0.aedStatus } }
    var keypointAge: TimeInterval? { nil }
    var lastNoTargetReason: NoTargetReason? { nil }
    func start() { state.withLock { $0.startCount += 1 } }
    func stop() {}
    func apply(_ effect: RescueEffect) {
        state.withLock { state in
            state.applied.append(effect)
            // As VisionSession does: any overlay change ends the guide.
            if case .overlay = effect { state.showsHandsGuide = false }
        }
    }
    func beginFrameBurst() { state.withLock { $0.bursts += 1 } }
    func overlay() -> VisionOverlay { state.withLock { $0.overlay } }
    func placeInjuryPin(atViewPoint point: CGPoint) async -> InjuryPinResult {
        state.withLock {
            $0.pinTaps.append(point)
            return $0.pinResult
        }
    }
    func requestLocate(_ materials: Set<RescueCore.Material>) { state.withLock { $0.locateRequests.append(materials) } }
    func locateStatus(_ material: RescueCore.Material) -> AEDStatus { state.withLock { $0.locateStatus[material] ?? .idle } }
    func sightings(of material: RescueCore.Material) -> Int { state.withLock { $0.sightings[material] ?? 0 } }
    func beginHandsGuide(seconds: TimeInterval) {
        state.withLock {
            $0.handsGuides.append(seconds)
            $0.showsHandsGuide = true
        }
    }
    var showsHandsGuide: Bool { state.withLock { $0.showsHandsGuide } }

    var ghostBeats: [Bool] { state.withLock { $0.ghostBeats } }
    var practicePlacements: [CGPoint?] { state.withLock { $0.practicePlacements } }
    var practiceClears: Int { state.withLock { $0.practiceClears } }
    /// No floor in view, so nothing can be placed.
    func setPracticePlaces(_ places: Bool) { state.withLock { $0.practicePlaces = places } }
    func setGhostBeat(on: Bool) { state.withLock { $0.ghostBeats.append(on) } }
    func placePracticePatient(atViewPoint point: CGPoint?) async -> Bool {
        state.withLock {
            $0.practicePlacements.append(point)
            return $0.practicePlaces
        }
    }
    func clearPracticePatient() { state.withLock { $0.practiceClears += 1 } }
}

func shippedBundle() throws -> ProtocolBundle {
    try #require(ProtocolLoader.load(from: .main), "clinical/ did not ship in the app bundle")
}

/// What the app runs. `shippedBundle()` stays core only, for the arrest suites.
func mergedBundle() throws -> ProtocolBundle {
    try #require(ProtocolLoader.loadMerged(from: .main), "clinical/ did not ship in the app bundle")
}

func toolContract() throws -> Data {
    let url = try #require(Bundle.main.url(forResource: "tools.v1", withExtension: "json", subdirectory: "contracts"))
    return try Data(contentsOf: url)
}

@MainActor
final class Fixture {
    let clock = TestClock()
    let audio = FakeAudio()
    let vision: FakeVision
    let gate = UplinkGate()
    /// Arrest sessions. An awake state's session gets `awakeMock`, so that each mode's sockets count alone.
    let mock = MockTransport()
    let awakeMock = MockTransport()
    let coordinator: AppCoordinator
    private(set) var sessions = 0
    private var markers = 0

    /// `live: false` is the no-key path, where the factory has nothing to give.
    init(
        live: Bool = false,
        auditor: Auditor? = nil,
        canLocate: Bool = false,
        arSupported: Bool = false,
        cameraAllowed: Bool = false,
        bundle: ProtocolBundle? = nil,
        makeLive: (@MainActor (LiveMode) -> LiveStack?)? = nil
    ) throws {
        let engine = ProtocolEngine(bundle: try bundle ?? shippedBundle())
        let vision = FakeVision(supported: arSupported)
        self.vision = vision
        let clock = clock
        let mock = mock
        let awakeMock = awakeMock
        var count = 0
        coordinator = AppCoordinator(
            engine: engine,
            audio: audio,
            vision: vision,
            gate: gate,
            canLocate: canLocate,
            makeLive: makeLive ?? { mode in
                guard live else { return nil }
                count += 1
                return LiveStack(
                    session: LiveSession(transport: mode == .awake ? awakeMock : mock, clock: clock.reader, mode: mode),
                    auditor: auditor
                )
            },
            clock: clock.reader,
            cameraAllowed: { cameraAllowed },
            runsTickLoop: false
        )
    }

    /// Walks the clock in tick-sized steps, so timeouts fire the way they do on a device.
    func run(seconds: TimeInterval) {
        var left = seconds
        while left > 0 {
            clock.advance(0.2)
            coordinator.tick()
            left -= 0.2
        }
    }

    func beginAndConnect() async throws {
        coordinator.beginRescue()
        try await waitUntil("a connection was opened") { self.mock.requests.count == 1 }
        mock.emit(.ready)
        try await waitUntil("the link came up") { self.coordinator.liveConnected }
    }

    /// The inbox keeps its order, so once this marker lands everything sent before it has too.
    func settleInbox() async throws {
        markers += 1
        let marker = "inbox_marker_\(markers)"
        audio.onPhraseFinished?(marker)
        try await waitUntil("the inbox drained") { self.logDetails(.phrasePlayed).contains(marker) }
    }

    func logDetails(_ kind: LogEntry.Kind) -> [String] {
        coordinator.log.entries.filter { $0.kind == kind }.map(\.detail)
    }

    /// Tells the session this policy through the real command path, and waits until it has it.
    func settleSessionPolicy(_ policy: RuntimePolicy) async {
        gate.setPolicy(policy)
        gate.send(.policy(policy))
        try? await Task.sleep(for: .milliseconds(50))
    }
}

@MainActor
func waitUntil(_ what: String, _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("Timed out waiting: \(what)", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// Sends a marker the policy allows, then waits for it. Anything blocked before it would have
/// arrived first, since the path is in order, so a later check for absence means something.
extension MockTransport {
    var sentAudio: [Data] {
        sent.compactMap { if case let .audio(data) = $0 { data } else { nil } }
    }
    var sentFrames: [Data] {
        sent.compactMap { if case let .frame(jpeg) = $0 { jpeg } else { nil } }
    }
    var sentBriefs: [StateBrief] {
        sent.compactMap { if case let .stateBrief(brief, _) = $0 { brief } else { nil } }
    }
    var kicks: Int {
        sent.filter { $0 == .kick }.count
    }
    /// Connections opened and not yet closed. A socket left in here after a stop is a leak.
    var openCount: Int {
        requests.count - closedCount
    }
}

func reportFindingCall(_ kind: String, version: Int, id: String = "call-1") -> RealtimeFunctionCall {
    RealtimeFunctionCall(id: id, name: "report_finding", args: [
        "kind": .string(kind),
        "source": "heard",
        "confidence": "high",
        "state_version": .number(Double(version)),
    ])
}

/// A reply in the shape generateContent uses.
func auditorHTTP(category: String) -> HTTPClient {
    { request in
        let text = #"{\"category\":\"\#(category)\"}"#
        let body = #"{"candidates":[{"content":{"parts":[{"text":"\#(text)"}]}}]}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}
