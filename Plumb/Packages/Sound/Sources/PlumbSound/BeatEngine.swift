import AVFoundation
import PlumbContracts
import Synchronization

/// The rescuer's whole interface: a steady beat and, now and then, one short spoken cue.
///
/// Threading: call the public methods from the main thread. The sound itself is made on the
/// audio thread, which shares a handful of atomics with everything else and never waits.
/// The engine's bookkeeping sits behind one lock, so a call that does arrive from another thread
/// (model speech from a network callback, say) cannot corrupt it. `beatPhase`, `setBeatAudible`
/// and `markReached` take no lock at all.
public final class BeatEngine: Sendable {
    /// The targets this engine was made for. The beat's tempo is `targets.beatPerMin`.
    public let targets: Targets
    /// The numbers this engine was made with.
    public let config: Config

    private let synth: ClickSynth
    private let clock = BeatClock()
    private let hostClock = HostClock()
    private let playhead: Playhead
    private let speaker: any CueSpeaking
    private let output: AudioGraph.Output
    private let control: Mutex<Control>

    /// Everything the lock guards.
    private struct Control {
        var graph: AudioGraph?
        var watcher: OutageWatcher?
        /// True between `start()` and `stop()`, even while an outage has the engine stopped.
        var wantsRunning = false
        var timeline: SpeechTimeline
        var library: CueLibrary
        var cueBuffers: [Cue: AVAudioPCMBuffer]
        /// Brings model speech to the engine's sample rate. Kept from one piece to the next so
        /// the joins cannot be heard; nil when no model speech is in flight.
        var modelResampler: StreamResampler?
        var preparation: Task<Void, Never>?
    }

    /// Makes an engine that speaks its cues with the system voice.
    public convenience init(targets: Targets = .adult, config: Config = .init()) {
        self.init(targets: targets, config: config, speaker: SystemCueSpeaker(config: config))
    }

    /// Makes an engine whose cue phrases are rendered by `speaker` instead of the system voice.
    public convenience init(targets: Targets, config: Config, speaker: any CueSpeaking) {
        self.init(targets: targets, config: config, speaker: speaker, output: .speaker)
    }

    init(targets: Targets, config: Config, speaker: any CueSpeaking, output: AudioGraph.Output) {
        self.targets = targets
        self.config = config
        self.speaker = speaker
        self.output = output
        synth = ClickSynth(beatsPerMinute: targets.beatPerMin, config: config)
        playhead = Playhead(config: config)
        // Until speech has been rendered every cue is its tone pattern, so a cue is never silent.
        let library = CueLibrary(config: config)
        control = Mutex(Control(timeline: Self.emptyTimeline(config), library: library,
                                cueBuffers: Self.buffers(for: library)))
    }

    // MARK: - Getting ready

    /// Builds the audio graph and renders the spoken cues, so that starting and speaking are instant.
    /// Calling it again does nothing new: every call waits for the same single preparation.
    public func prepare() async {
        let task = control.withLock { control in
            if let underway = control.preparation { return underway }
            let task = Task { await self.buildGraphAndCues() }
            control.preparation = task
            return task
        }
        await task.value
    }

    /// Which cues are spoken words and which are tone patterns, and why. Before `prepare()` has
    /// finished, every cue is a tone pattern.
    public var cueReport: CueRenderReport {
        control.withLock { $0.library.report }
    }

    private func buildGraphAndCues() async {
        // A graph that cannot be built is not reported here: `start()` tries again and can throw.
        control.withLock { _ = try? readyGraph(&$0) }
        let library = await CueLibrary.rendered(by: speaker, config: config)
        control.withLock { control in
            control.library = library
            control.cueBuffers = Self.buffers(for: library)
        }
    }

    // MARK: - Running

    /// Starts the beat from its first sample. Does nothing if it is already running.
    /// Works without `prepare()`, but then cues are tone patterns until it has been called.
    public func start() throws {
        try control.withLock { control in
            if control.wantsRunning, control.graph?.engine.isRunning == true { return }
            try launch(&control)
            control.wantsRunning = true
        }
    }

    /// Stops all sound. The next `start()` begins again at phase 0 on the thin click, as if no
    /// compression had been seen yet.
    public func stop() {
        control.withLock { control in
            control.wantsRunning = false
            halt(&control)
        }
        clock.reached.store(false, ordering: .relaxed)
        #if os(iOS)
        if ownsSession { SpeakerSession.release() }
        #endif
    }

    /// Whether sound is being made right now. False while a phone call or similar has the output.
    public var isRunning: Bool {
        control.withLock { $0.wantsRunning && $0.graph?.engine.isRunning == true }
    }

    /// Turns the clicks on or off from the next beat. The beat keeps counting while silent, so it
    /// comes back in phase.
    public func setBeatAudible(_ on: Bool) {
        clock.audible.store(on, ordering: .relaxed)
    }

    /// Says whether the last compression reached the line. It picks the sound of the next beat and
    /// every beat after, until told otherwise: a low full "tock" for true, a thin "tick" for false.
    public func markReached(_ reached: Bool) {
        clock.reached.store(reached, ordering: .relaxed)
    }

    /// Position inside the current beat as it is heard, from 0 at the click up to but not reaching 1.
    /// 0 while stopped. Cheap enough to read every display frame.
    public var beatPhase: Double {
        let heard = playhead.heardFrame(generated: clock.nextFrame.load(ordering: .relaxed),
                                        anchorSeconds: clock.anchorSeconds.load(ordering: .relaxed),
                                        nowSeconds: hostClock.now,
                                        latencySeconds: clock.outputLatencySeconds.load(ordering: .relaxed))
        return synth.phase(atSample: Int(heard))
    }

    // MARK: - Speaking

    /// Speaks a cue once, ducking the beat while it plays. Ignored while another cue is playing,
    /// unless the new one is "push now", which cuts in. Ignored while the engine is not running.
    public func speak(_ cue: Cue) {
        control.withLock { control in
            guard let graph = control.graph, graph.engine.isRunning,
                  let buffer = control.cueBuffers[cue] else { return }
            let now = clock.nextFrame.load(ordering: .relaxed)
            guard control.timeline.admits(cue, at: now) else { return }
            // A cue outranks the model's voice and any cue it is allowed to interrupt.
            cutModelSpeech(&control)
            graph.cuePlayer.stop()
            graph.cuePlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            graph.cuePlayer.play()
            control.timeline.cueStarted(cue, at: now, frames: Int64(buffer.frameLength))
            clock.duckUntilFrame.store(control.timeline.duckEnd, ordering: .relaxed)
        }
    }

    /// Queues speech from a voice model behind any already queued, ducking the beat while it plays.
    /// `pcm16` is 16-bit little-endian mono. Audio that arrives while a cue is playing is dropped,
    /// not held: a sentence resumed with its middle missing would only confuse.
    public func playModelAudio(pcm16: Data, sampleRate: Double) {
        guard config.modelSampleRateRange.contains(sampleRate) else { return }
        playSpeech(MonoClip(pcm16: pcm16, sampleRate: sampleRate))
    }

    /// Queues speech made on the phone, such as a fixed answer read by the system voice, on the
    /// same lane as model speech: under the cues, cut the moment a cue starts, and dropped if it
    /// arrives while one is playing. A cue is never held back or cut short by it.
    public func playSpeech(_ speech: MonoClip) {
        let sampleRate = speech.sampleRate
        guard config.modelSampleRateRange.contains(sampleRate) else { return }
        control.withLock { control in
            guard let graph = control.graph, graph.engine.isRunning else { return }
            let now = clock.nextFrame.load(ordering: .relaxed)
            guard !control.timeline.cuePlaying(at: now) else { return }
            if control.modelResampler?.sourceRate != sampleRate {
                control.modelResampler = StreamResampler(from: sampleRate, to: config.sampleRate, config: config)
            }
            guard let samples = control.modelResampler?.process(speech.samples),
                  let buffer = MonoClip(samples: samples, sampleRate: config.sampleRate).makeBuffer() else { return }
            graph.modelPlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            if !graph.modelPlayer.isPlaying { graph.modelPlayer.play() }
            control.timeline.modelQueued(at: now, frames: Int64(buffer.frameLength))
            clock.duckUntilFrame.store(control.timeline.duckEnd, ordering: .relaxed)
        }
    }

    /// Cuts off model speech at once and forgets whatever was queued.
    public func stopModelAudio() {
        control.withLock { control in
            cutModelSpeech(&control)
            control.timeline.modelStopped(at: clock.nextFrame.load(ordering: .relaxed))
            clock.duckUntilFrame.store(control.timeline.duckEnd, ordering: .relaxed)
        }
    }

    // MARK: - Offline

    /// Pulls the next `frameCount` samples out of an engine made for offline output.
    /// This is how the tests hear the real graph.
    func renderOffline(frameCount: Int) throws -> [Float] {
        try control.withLock { control in
            guard let graph = control.graph else { throw OfflinePullError.notOffline }
            return try graph.renderOffline(frameCount: frameCount)
        }
    }

    // MARK: - Inner workings

    private func readyGraph(_ control: inout Control) throws -> AudioGraph {
        if let graph = control.graph { return graph }
        #if os(iOS)
        if ownsSession { try SpeakerSession.claim(sharesMicrophone: config.sharesMicrophone) }
        #endif
        let renderer = BeatRenderer(synth: synth, clock: clock, hostClock: hostClock, config: config)
        let graph = try AudioGraph(config: config, renderer: renderer, output: output)
        control.graph = graph
        if case .speaker = output {
            control.watcher = OutageWatcher(engine: graph.engine) { [weak self] in
                self?.startAgainAfterOutage()
            }
        }
        return graph
    }

    private func launch(_ control: inout Control) throws {
        let graph = try readyGraph(&control)
        #if os(iOS)
        if ownsSession { try SpeakerSession.activate() }
        #endif
        clock.rewind()
        control.timeline = Self.emptyTimeline(config)
        try graph.engine.start()
        if case .speaker = output {
            clock.outputLatencySeconds.store(graph.engine.outputNode.presentationLatency, ordering: .relaxed)
        }
    }

    private func cutModelSpeech(_ control: inout Control) {
        control.graph?.modelPlayer.stop()
        // The end of a sentence that was cut must not leak into the start of the next.
        control.modelResampler = nil
    }

    private func halt(_ control: inout Control) {
        guard let graph = control.graph else { return }
        graph.cuePlayer.stop()
        cutModelSpeech(&control)
        graph.engine.stop()
        clock.rewind()
        control.timeline = Self.emptyTimeline(config)
    }

    private func startAgainAfterOutage() {
        control.withLock { control in
            halt(&control)
            // A fresh graph picks up whatever format the hardware has now.
            control.watcher = nil
            control.graph = nil
            guard control.wantsRunning else { return }
            // If the output is not back yet this fails and the engine stays stopped, with
            // `isRunning` false. The next notice, or the next `start()`, tries again.
            try? launch(&control)
        }
    }

    #if os(iOS)
    private var ownsSession: Bool {
        guard case .speaker = output else { return false }
        return config.managesAudioSession
    }
    #endif

    private static func emptyTimeline(_ config: Config) -> SpeechTimeline {
        SpeechTimeline(tailFrames: Int64((config.speechTailSeconds * config.sampleRate).rounded()))
    }

    private static func buffers(for library: CueLibrary) -> [Cue: AVAudioPCMBuffer] {
        var buffers: [Cue: AVAudioPCMBuffer] = [:]
        for cue in Cue.allCases {
            buffers[cue] = library.clip(for: cue).makeBuffer()
        }
        return buffers
    }
}

/// Why the engine could not start.
public enum BeatEngineError: Error, Equatable, Sendable {
    /// The configured sample rate is not one the audio system can use.
    case unusableSampleRate
}
