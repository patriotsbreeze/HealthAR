import CoreGraphics
import Foundation
import PlumbAgents
import PlumbCapture
import PlumbContracts
import PlumbSession
import QuartzCore
import simd

/// The language-model helpers, present only when a Gemini key is configured.
///
/// None of them can touch the beat, the cues or the measurements. The voice can only read the
/// measurements through one tool; the scribe's sentences reach the screen only after a fixed checker
/// has passed every number in them; the AED finder's guesses are tested against the depth sensor.
/// Everything they do is written to the session log, so the show-working screen can show it.
@MainActor
final class AgentsHub {
    /// Writes one line to the session log at the current session time.
    var record: (LogEntry.Source, LogEntry.Body) -> Void = { _, _ in }
    /// Plays speech that arrived from the voice model, under the coaching cues.
    var playModelAudio: (Data) -> Void = { _ in }

    let config = AgentsConfig()
    let client: GeminiClient
    private let conductor: Conductor
    private let voice: VoiceSession
    private var mic: MicCapture?
    private var micRunning = false
    private var voiceConnected = false
    private var connecting: Task<Void, Never>?
    private var talking = false
    private var searching = false
    private var latest = WorldDigestBuilder.unknown

    private init(apiKey: String) {
        client = GeminiClient(apiKey: apiKey)
        let sink = SinkBox()
        conductor = Conductor(config: config, now: { CACurrentMediaTime() }, sink: { body in sink.send(body) })
        voice = VoiceSession(apiKey: apiKey, socketFactory: { URLSessionRealtimeSocket(request: $0) },
                             conductor: conductor, config: config)
        sink.target = self
        Task { [conductor] in
            await conductor.register(GetCPRQuality(read: { [weak self] in
                await self?.digest() ?? WorldDigestBuilder.unknown
            }))
        }
        Task { [weak self, events = voice.events] in
            for await event in events { self?.handle(event) }
        }
    }

    /// Nil when the app was built without a key, which is a normal way to run: nothing else needs the network.
    static func makeIfConfigured() -> AgentsHub? {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "GeminiAPIKey") as? String else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return AgentsHub(apiKey: trimmed)
    }

    /// Keeps the newest measurements for the voice's tool to read. Called on every tick.
    func publish(metrics: Metrics, now: TimeInterval) {
        latest = WorldDigestBuilder.make(metrics: metrics, now: now)
    }

    private func digest() -> WorldDigest {
        latest
    }

    // MARK: - Scribe

    /// Asks the scribe for up to three sentences, each checked number by number against the log.
    func writeHandoff(log: [LogEntry], stats: HandoffStats, headline: String) async -> ScribeResult {
        let scribe = Scribe(client: client, config: config)
        return await scribe.write(log: log, stats: stats, headline: headline) { sentences in
            ScribeVerifier.verify(sentences, log: log, stats: stats)
        }
    }

    // MARK: - Hold to ask

    /// Opens the voice connection ahead of the first question, so the first answer is not slowed by setup.
    func warmUp() {
        guard !voiceConnected, connecting == nil else { return }
        connecting = Task { [voice] in
            await voice.connect()
        }
    }

    /// True while this hub's microphone runs, which lasts a moment past the release. The phone's own
    /// listening has a microphone of its own, and the two must never run at once.
    var microphoneInUse: Bool { talking || micRunning }

    /// True while the connection to the voice service is open, so a question asked now can be heard.
    /// False before it first opens and after it drops, until `warmUp` has opened it again.
    var isVoiceReady: Bool { voiceConnected }

    /// Push-to-talk, pressed: opens a turn and the microphone. The app has already checked the microphone
    /// is allowed. Returns whether listening started.
    func beginAsking() -> Bool {
        guard !talking else { return false }
        talking = true
        warmUp()
        do {
            try microphone().start()
            micRunning = true
            voice.beginTalking()
            return true
        } catch {
            talking = false
            record(.system, .note("Microphone could not start."))
            return false
        }
    }

    /// Push-to-talk, let go: closes the turn so the model answers.
    func endAsking() {
        guard talking else { return }
        talking = false
        voice.endTalking()
        // A short tail so the last word is not cut off before the turn closes.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !self.talking else { return }
            self.mic?.stop()
            self.micRunning = false
        }
    }

    private func microphone() -> MicCapture {
        if let mic { return mic }
        let made = MicCapture(config: config) { [voice] chunk in voice.sendAudio(pcm16k: chunk) }
        mic = made
        return made
    }

    private func handle(_ event: VoiceEvent) {
        switch event {
        case .connected:
            voiceConnected = true
            connecting = nil
        case .disconnected(let reason):
            voiceConnected = false
            connecting = nil
            record(.system, .note("Voice closed: \(reason)"))
        case .failed(let reason):
            record(.system, .note("Voice failed: \(reason)"))
        case .heard(let text):
            record(.said, .note("Asked: \(text)"))
        case .replied(let text):
            record(.model, .note("Answered: \(text)"))
        case .speaking(let pcm):
            playModelAudio(pcm)
        case .toolCalled, .turnEnded:
            // Tool calls are logged by the conductor with their duration and outcome.
            break
        }
    }

    // MARK: - Find AED

    /// Looks for the AED: a model points at candidates in one still, the depth sensor tests each for a
    /// real object of the right size standing out from its surroundings, and only an accepted one gets a
    /// marker. A flat sign or a picture of an AED is rejected. The still leaves the phone only with every
    /// person in it filled in. Runs at most one search at a time.
    func findAED(in feed: SignalFeed) {
        guard !searching else { return }
        searching = true
        Task { @MainActor [weak self] in
            await self?.search(feed)
            self?.searching = false
        }
    }

    private func search(_ feed: SignalFeed) async {
        // Read before the still is asked for: a still the camera gives after starting over belongs to a
        // world this search did not begin in, so it is dropped as well.
        let run = feed.captureRun
        guard let raw = await feed.sceneSnapshot() else {
            record(.system, .note(feed.isReplay ? "Find AED needs the camera; this is a replay."
                                                : "No camera picture with depth yet."))
            return
        }
        let hiding = CACurrentMediaTime()
        guard let snapshot = await raw.hidingPeople(), let hidden = snapshot.peopleHidden else {
            // Shown on show working as a refusal: the picture stayed on the phone.
            record(.rule, .blocked(what: "Send picture",
                                   rule: "Could not hide the people in the picture, so nothing was sent."))
            return
        }
        // Shown on show working beside the search it made safe to send.
        record(.system, .toolCall(name: "hide_people", durationS: CACurrentMediaTime() - hiding, ok: true,
                                  summary: hidden.sentence))
        let config = self.config
        let started = CACurrentMediaTime()
        let finder = SceneFinder(client: client, config: config)
        let result = await finder.find(label: config.sceneLabel) { region in
            let rect = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
            guard let jpeg = snapshot.jpeg(region: rect) else { return nil }
            return SceneCapture(jpeg: jpeg) { point in Self.probe(snapshot, at: point, config: config) }
        }
        for body in result.logBodies { record(.model, body) }
        let seconds = CACurrentMediaTime() - started
        guard let hit = result.accepted, let depth = hit.verdict.distanceM else {
            record(.model, .toolCall(name: "find_aed", durationS: seconds, ok: false,
                                     summary: "No AED the depth sensor agreed with."))
            return
        }
        // The camera may have started over while the model looked, as for a new rescue. Its new world has a
        // new origin and heading, so this point would stand somewhere else in it.
        guard feed.captureRun == run else {
            record(.model, .toolCall(name: "find_aed", durationS: seconds, ok: false,
                                     summary: "The camera restarted during the search; no marker placed."))
            return
        }
        let world = snapshot.worldPoint(at: CGPoint(x: hit.point.x, y: hit.point.y), depthM: depth)
        let metres = simd_distance(world, snapshot.cameraPosition)
        feed.placeAEDMarker(at: world)
        record(.model, .toolCall(name: "find_aed", durationS: seconds, ok: true,
                                 summary: String(format: "AED marked %.1f m away.", metres)))
    }

    /// Depth around one proposed point, on a grid wide enough to show the surface around the object.
    private nonisolated static func probe(_ snapshot: SceneSnapshot, at point: ScenePoint,
                                         config: AgentsConfig) -> SceneProbe? {
        let centre = CGPoint(x: point.x, y: point.y)
        guard let near = snapshot.depthGrid(around: centre, sidePx: 24, cells: 5) else { return nil }
        let readings = near.depthsM.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !readings.isEmpty,
              let side = SceneProbe.patchSidePx(centreDepthM: readings[readings.count / 2],
                                                focalLengthPx: near.focalLengthPx, config: config),
              let grid = snapshot.depthGrid(around: centre, sidePx: side, cells: 24) else { return nil }
        return SceneProbe(depthsM: grid.depthsM, gridWidth: grid.width, gridHeight: grid.height,
                          focalLengthPx: grid.focalLengthPx, patchWidthPx: grid.widthPx, patchHeightPx: grid.heightPx)
    }
}

/// Carries the conductor's log lines to the hub. The conductor is made before the hub exists, so the
/// hub is attached afterwards; lines arriving before that are dropped.
private final class SinkBox: @unchecked Sendable {
    // Written once on the main thread before any tool can run, then only read.
    weak var target: AgentsHub?

    func send(_ body: LogEntry.Body) {
        Task { @MainActor [weak self] in self?.target?.record(.model, body) }
    }
}

extension WorldDigestBuilder {
    /// What a question is answered from when nothing is known: no hands seen, and too old to trust.
    static var unknown: WorldDigest {
        WorldDigest(lock: .lost, count: 0, ratePerMin: nil, depthMM: nil, depthSpreadMM: nil, isPaused: false,
                    pauseSeconds: 0, handsOnFraction: nil, ageS: .infinity, stale: true)
    }
}
