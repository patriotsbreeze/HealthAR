import Foundation
import Observation
import PlumbAgents
import PlumbCoach
import PlumbContracts
import PlumbSession
import PlumbSignal
import PlumbSound
import PlumbUI
import QuartzCore

/// Runs one rescue: samples in, compressions counted, one cue at a time out, and the record kept.
///
/// Everything here runs on the main thread. Samples arrive at up to 60 a second and each costs
/// microseconds; the screen state the views observe changes only on the 10 Hz tick, and the bars
/// read their own model once a frame without going through SwiftUI.
@MainActor
@Observable
final class RescueController {
    enum Screen: Equatable {
        case rescue
        case working
        case handoff
        /// The chest check, offered before the first push.
        case chest
    }

    private(set) var screen: Screen = .rescue
    private(set) var command: String?
    private(set) var tone: CommandTone = .fix
    private(set) var metrics = Metrics.empty
    private(set) var elapsed: Double = 0
    private(set) var handoff: HandoffResult?
    /// What the chest check sees, while its screen is up.
    private(set) var chest: ChestReading?
    /// True while measurements are being recorded to a file.
    private(set) var isRecording = false
    /// Seconds of still hands after which "Hand over" replaces "Hold to ask".
    let handOverAfterPauseS: Double = 3

    @ObservationIgnored let bars = BarFieldModel()
    @ObservationIgnored let feed: SignalFeed
    @ObservationIgnored let targets = Targets.adult
    @ObservationIgnored private let beat: BeatEngine
    @ObservationIgnored private let agents: AgentsHub?
    @ObservationIgnored private let asking: AskRouter
    @ObservationIgnored private let narrator: Narrator
    @ObservationIgnored private var analyzer = CompressionAnalyzer()
    @ObservationIgnored private var chestCheck = ChestMovementAnalyzer()
    @ObservationIgnored private var policy = CuePolicy()
    @ObservationIgnored private var recorder = SessionRecorder(startedWallClock: Date())
    @ObservationIgnored private var clockStart = CACurrentMediaTime()
    /// Feed time minus this app's clock, learned from the first sample, so ticks and samples share one timeline.
    @ObservationIgnored private var feedOffset: Double?
    @ObservationIgnored private var lastSampleT: Double = -.infinity
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var pendingEvents: [SignalEvent] = []
    @ObservationIgnored private var soundReady = false

    init(feed: SignalFeed) {
        self.feed = feed
        let agents = AgentsHub.makeIfConfigured()
        var sound = BeatEngine.Config()
        // "Hold to ask" works with or without a key, so the beat always leaves room for the microphone.
        sound.sharesMicrophone = true
        beat = BeatEngine(targets: Targets.adult, config: sound)
        narrator = Narrator(beat: beat)
        self.agents = agents
        asking = AskRouter(agents: agents)
        agents?.record = { [weak self] source, body in self?.recordFromAgents(source, body) }
        agents?.playModelAudio = { [weak self] pcm in self?.beat.playModelAudio(pcm16: pcm, sampleRate: 24_000) }
        asking.record = { [weak self] source, body in self?.recordFromAgents(source, body) }
        // An answer worked out after the hand over is not said: the handoff screen reads only the record.
        asking.speak = { [weak self] answer in
            guard let self, self.screen != .handoff else { return }
            self.narrator.answer(answer)
        }
        feed.onPictureTapped = { [weak self] in self?.pictureTapped() }
    }

    /// Agent and question activity goes into the same log as everything else, stamped with session time.
    private func recordFromAgents(_ source: LogEntry.Source, _ body: LogEntry.Body) {
        guard screen != .handoff else { return }
        recorder.record(t: now(), source: source, body: body)
    }

    /// True once pushing has started and then stopped long enough that a crew may be taking over.
    var offersHandOver: Bool {
        metrics.count > 0 && metrics.isPaused && metrics.pauseSeconds >= handOverAfterPauseS
    }

    var rateInRange: Bool {
        guard let rate = metrics.ratePerMin else { return true }
        return rate >= targets.rateMinPerMin && rate <= targets.rateMaxPerMin
    }

    /// The first instruction, shown until the first push.
    var startPrompt: String? {
        metrics.count == 0 ? "Hands on the centre of the chest. Push hard and fast." : nil
    }

    /// The chest check is offered only before the first push: once pushing has started it has nothing to add.
    var offersChestCheck: Bool { metrics.count == 0 }

    // MARK: - Lifecycle

    /// Prepares sound and starts the first rescue. The beat starts within the first second: pushing is the start button.
    /// Measuring starts at once; rendering the spoken cues can take seconds, so the beat joins when it is ready.
    func begin() async {
        startRescue()
        #if DEBUG
        scheduleDebugJump()
        #endif
        Task { await asking.prepare() }
        await beat.prepare()
        soundReady = true
        // On the chest screen the beat runs silent, so a cue can still be spoken there.
        if screen != .handoff { try? beat.start() }
    }

    /// A fresh rescue on a freshly started feed: a new world and a new clock.
    private func startRescue() {
        resetRescue()
        feed.start { [weak self] sample in self?.ingest(sample) }
    }

    /// Everything a fresh rescue starts from, apart from the feed, which goes on as it is. The session clock
    /// learns the feed's time again from the next sample.
    private func resetRescue() {
        // A question still being asked belongs to the rescue that is ending.
        asking.cancel()
        analyzer.reset()
        policy.reset()
        bars.reset()
        recorder = SessionRecorder(startedWallClock: Date())
        clockStart = CACurrentMediaTime()
        feedOffset = nil
        lastSampleT = -.infinity
        pendingEvents.removeAll()
        command = nil
        metrics = .empty
        elapsed = 0
        handoff = nil
        chest = nil
        if feed.isRecording { _ = feed.setRecording(false) }
        isRecording = false
        screen = .rescue
        // The beat may still be running, silent, from the chest screen: a fresh rescue starts on the thin click.
        beat.setBeatAudible(true)
        beat.markReached(false)
        if soundReady { try? beat.start() }
        agents?.warmUp()
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.tick()
            }
        }
    }

    /// The session clock, in the same seconds as the samples.
    private func now() -> Double {
        let raw = CACurrentMediaTime() - clockStart
        return max(raw + (feedOffset ?? 0), lastSampleT)
    }

    // MARK: - Per sample

    private func ingest(_ sample: HeightSample) {
        guard screen != .handoff else { return }
        if feedOffset == nil { feedOffset = sample.t - (CACurrentMediaTime() - clockStart) }
        lastSampleT = max(lastSampleT, sample.t)
        guard screen != .chest else {
            chestCheck.ingest(sample)
            return
        }
        let events = analyzer.ingest(sample)
        bars.update(analyzer.live)
        handle(events)
    }

    private func handle(_ events: [SignalEvent]) {
        guard !events.isEmpty else { return }
        recorder.record(events)
        pendingEvents.append(contentsOf: events)
        for event in events {
            switch event {
            case .compression(let stroke):
                let reached = stroke.lock == .locked && stroke.depthMM >= targets.depthMinMM
                bars.append(StrokeBar(depthMM: stroke.depthMM, reached: reached, trust: stroke.lock))
                beat.markReached(reached)
            case .pauseEnded:
                bars.setPause(seconds: 0)
            case .pauseStarted, .lockChanged:
                break
            }
        }
    }

    // MARK: - Ten times a second

    private func tick() {
        guard screen != .handoff else { return }
        let t = now()
        if isRecording, !feed.isRecording {
            isRecording = false
            recorder.record(t: t, source: .system, body: .note("Recording ended."))
        }
        guard screen != .chest else {
            tickChest(at: t)
            return
        }
        handle(analyzer.tick(now: t))
        metrics = analyzer.metrics
        elapsed = t
        if metrics.isPaused { bars.setPause(seconds: metrics.pauseSeconds) }

        let decision = policy.update(metrics: metrics, events: pendingEvents, now: t)
        pendingEvents.removeAll(keepingCapacity: true)
        if let cue = decision.speak {
            beat.speak(cue)
            recorder.record(cue: cue, at: t)
        }
        command = decision.show?.commandText
        tone = decision.show == .good ? .affirm : .fix
        agents?.publish(metrics: metrics, now: t)
        asking.publish(metrics: metrics, now: t)
        // The ring and the target line stand in the world on the rescue screen only, the line only while pushing.
        feed.setGuides(lock: metrics.lock, compressing: metrics.count > 0 && !metrics.isPaused,
                       visible: screen == .rescue)
    }

    // MARK: - Screens

    func showWorking() { screen = .working }
    func backToRescue() { screen = .rescue }

    // MARK: - Chest check

    /// Opens the chest check. The pushes stop being counted and the beat goes silent; the box that measured
    /// the hands is dropped, and the presenter taps the chest on the picture to watch it instead.
    func checkChest() {
        guard screen == .rescue || screen == .working else { return }
        // A recording is of pushes: the chest's box would replay as compressions.
        if isRecording {
            isRecording = feed.setRecording(false)
            recorder.record(t: now(), source: .system, body: .note("Recording stopped for the chest check."))
        }
        // A person asked for it, so the check starts fresh, prompt and all.
        chestCheck.reset()
        chest = chestCheck.tick(now: now())
        command = nil
        beat.setBeatAudible(false)
        feed.setGuides(lock: metrics.lock, compressing: false, visible: false)
        feed.setChestMode(true)
        screen = .chest
    }

    /// "Start pushing" on the chest screen: a fresh rescue with the beat on. The feed is not restarted: its
    /// clock and its world go on, so nothing measured before can land on a new clock, and an AED marker stays
    /// where it stands. Only the box on the chest goes, and the hands are looked for again.
    ///
    /// The new record opens with why pushing began, when the check had prompted it, and then what the check
    /// last saw, when it had seen enough to say.
    func startPushingFromChest() {
        guard screen == .chest else { return }
        let last = chestCheck.tick(now: now())
        let prompted = last.promptNoteBeforeCPR(stillForS: chestCheck.config.noMovementAfterS)
        let seen = last.state.noteBeforeCPR
        feed.setChestMode(false)
        resetRescue()
        if let prompted { recorder.record(t: 0, source: .rule, body: .note(prompted)) }
        if let seen { recorder.record(t: 0, source: .measured, body: .note(seen)) }
    }

    /// "Back" on the chest screen: the rescue screen as it was, with nothing started.
    func backFromChest() {
        guard screen == .chest else { return }
        feed.setChestMode(false)
        chest = nil
        beat.setBeatAudible(true)
        screen = .rescue
    }

    /// Reads the chest, and speaks "Push now" once, the moment the check first prompts "Start pushing".
    private func tickChest(at t: Double) {
        chestCheck.noiseFloorMM = feed.stillPointNoiseMM
        let reading = chestCheck.tick(now: t)
        if reading.startPushing, chest?.startPushing != true {
            beat.speak(.pushNow)
            recorder.record(cue: .pushNow, at: t)
        }
        chest = reading
    }

    /// A tap on the picture has moved the measuring box; every sample from here on comes from the new one.
    /// On the chest screen the check starts watching afresh, so the jump to the new patch is not read as
    /// movement.
    private func pictureTapped() {
        if screen == .chest { chestCheck.restartWatching() }
    }

    // MARK: - Recording

    /// Starts or stops recording what the sensors measure, from the show-working screen.
    func setRecording(_ on: Bool) {
        guard on != isRecording else { return }
        isRecording = feed.setRecording(on)
        let words = on ? (isRecording ? "Recording the measurements to a file." : "Recording could not start.")
                       : "Recording stopped."
        recorder.record(t: now(), source: .tapped, body: .note(words))
    }

    /// Ends the session and builds the record from the log. The model-written sentences, if any, arrive later.
    func handOver() {
        let t = now()
        let pauseStart = metrics.isPaused ? t - metrics.pauseSeconds : nil
        // Stopping the feed ends any recording.
        if isRecording { recorder.record(t: t, source: .system, body: .note("Recording ended at the hand over.")) }
        isRecording = false
        recorder.end(at: t, openPauseSince: pauseStart)
        // A question still being asked ends unanswered, and its microphone stops.
        asking.cancel()
        feed.stop()
        ticker?.cancel()
        beat.stop()
        let log = recorder.log.entries
        // About thirty slices whatever the length, so a one-minute demo and a ten-minute rescue both read as bars.
        let bucketS = min(10, max(2, (t / 30).rounded()))
        let stats = HandoffCalculator.stats(log: log, endT: t, targets: targets, bucketS: bucketS)
        let headline = HandoffText.headline(stats)
        handoff = HandoffResult(headline: headline, stats: stats, depthRange: HandoffText.depthRange(stats),
                                sentences: [], log: log)
        command = nil
        screen = .handoff
        guard let agents else { return }
        Task { @MainActor [weak self] in
            let result = await agents.writeHandoff(log: log, stats: stats, headline: headline)
            guard let self, self.screen == .handoff else { return }
            self.handoff?.sentences = result.accepted.map(\.text)
            self.handoff?.scribe = result
        }
    }

    func newRescue() { startRescue() }

    /// The app has left the foreground. A press of "Hold to ask" may never see its release now, so it ends
    /// here and the microphone stops.
    func leftForeground() {
        asking.cancel()
    }

    /// The session log so far, for the show-working view.
    var log: [LogEntry] { handoff?.log ?? recorder.log.entries }

    /// What the voice reads when "Read aloud" is pressed: the headline and the four numbers in words.
    func readAloud() {
        guard let handoff else { return }
        let s = handoff.stats
        var words = [handoff.headline]
        if let rate = s.ratePerMin { words.append("Rate \(Int(rate.rounded())) a minute.") }
        if let range = handoff.depthRange { words.append("Depth \(range).") }
        words.append("Reached five centimetres \(HandoffText.percent(s.reachedTargetFraction)).")
        words.append("Hands on chest \(HandoffText.percent(s.handsOnFraction)).")
        narrator.say(words.joined(separator: " "))
    }

    // MARK: - Agents

    var agentsAvailable: Bool { agents != nil }

    func askChanged(_ pressed: Bool) {
        asking.changed(pressed)
    }

    func findAED() {
        agents?.findAED(in: feed)
    }
}

/// The finished record shown on the handoff screen.
struct HandoffResult {
    var headline: String
    var stats: HandoffStats
    var depthRange: String?
    /// Model-written sentences that passed the checker. Empty until the scribe returns, and when it fails.
    var sentences: [String]
    var log: [LogEntry]
    var scribe: ScribeResult?
}

#if DEBUG
extension RescueController {
    /// Debug builds only: `-jump handoff 45`, `-jump working 30` or `-jump chest 30` moves to that screen after
    /// that many seconds, so screens can be checked in the Simulator without touch input.
    fileprivate func scheduleDebugJump() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-jump"), i + 2 < args.count, let delay = Double(args[i + 2]) else { return }
        let target = args[i + 1]
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            switch target {
            case "handoff": self.handOver()
            case "working": self.showWorking()
            case "chest": self.checkChest()
            default: break
            }
        }
    }
}
#endif
