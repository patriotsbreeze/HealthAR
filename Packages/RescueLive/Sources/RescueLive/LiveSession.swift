import Foundation
import RescueCore

public enum LiveTimingMetric: String, Sendable, CaseIterable {
    /// Connection attempt to the provider accepting setup.
    case setup
    /// Connection lost to the next one ready.
    case reconnectGap = "reconnect_gap"
    /// `sendAudioStreamEnd` to the first tool call after it.
    case speechEndToToolCall = "speech_end_to_tool_call"
    /// `sendAudioStreamEnd` to the first model audio after it.
    case speechEndToModelAudio = "speech_end_to_model_audio"
    /// One mode's session stopped to the next one ready. The app measures this, since a session
    /// knows only its own life.
    case modeSwap = "mode_swap"
}

public enum LiveEvent: Sendable, Equatable {
    case connected(resumed: Bool)
    case disconnected(LiveDisconnectReason)
    case proposal(ModelProposal)
    /// The voice model's read of the camera view. For the screen only; the engine never sees it.
    case scene(SceneReport)
    /// The rescuer's words chose a button on screen. The app decides whether to press it.
    case press(ButtonPress)
    case modelAudio(Data)
    case interrupted
    case turnComplete
    case inputTranscript(String)
    case outputTranscript(String)
    case usage(LiveUsage)
    case timing(LiveTimingMetric, seconds: TimeInterval)
}

/// One live conversation, over as many connections as it takes. Failure only ever shows up as an
/// event. No method here throws or waits on the network, so guidance never depends on it.
/// Make a new session for each rescue and each mode, because a kept resumption handle carries the
/// old context, and the prompt and contract are set at connect.
public actor LiveSession {
    public struct Configuration: Sendable {
        /// How long each attempt gets to finish setup, growing while they keep timing out, or a
        /// network that needs a little over the first value would never connect. The last repeats.
        public var setupTimeouts: [TimeInterval] = [3, 5, 8, 12]
        /// Delay before each retry. The last value repeats, for as long as the session runs.
        public var backoff: [TimeInterval] = [0.25, 0.5, 1, 2, 4]
        /// A connection that lived this long was fine, so failures restart from the first delay.
        public var stableConnectionSeconds: TimeInterval = 10
        /// About 500 ms of 16 kHz PCM. Older speech is no use once it's this late.
        public var maxQueuedAudioBytes = 16_000

        public init() {}
    }

    private enum Phase { case idle, connecting, ready, waitingToRetry }

    /// For one consumer.
    public nonisolated let events: AsyncStream<LiveEvent>
    private nonisolated let eventSink: AsyncStream<LiveEvent>.Continuation

    private let transport: any RealtimeTransport
    private let configuration: Configuration
    private let clock: @Sendable () -> TimeInterval
    private let router: ToolRouter

    private var phase = Phase.idle
    /// Bumped whenever a connection ends, so that anything late from it is ignored.
    private var generation = 0
    private var connection: (any RealtimeConnection)?
    private var inboundTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var queue: OutboundQueue

    private var resumeHandle: String?
    private var latestBrief: StateBrief?
    private var currentRequest = RealtimeConnectRequest(resumeHandle: nil, seedsHistory: false)
    private var failures = 0
    private var setupTimeoutsInARow = 0
    private var micUplink = true
    private var frameUplink = true

    private var connectStartedAt: TimeInterval = 0
    private var readyAt: TimeInterval = 0
    private var lostAt: TimeInterval?
    private var speechEndAt: TimeInterval?
    private var awaitingToolCall = false
    private var awaitingModelAudio = false

    /// `clock` must be the time base the engine uses, since `issuedAt` is checked against it.
    public init(
        transport: any RealtimeTransport,
        configuration: Configuration = Configuration(),
        clock: @escaping @Sendable () -> TimeInterval,
        mode: LiveMode = .arrest
    ) {
        self.transport = transport
        self.configuration = configuration
        self.clock = clock
        router = ToolRouter(clock: clock, allowedFindings: mode.allowedFindings)
        queue = OutboundQueue(maxAudioBytes: configuration.maxQueuedAudioBytes)
        // A consumer that stalls loses the oldest events, and the proposals among them would
        // have expired anyway.
        (events, eventSink) = AsyncStream.makeStream(of: LiveEvent.self, bufferingPolicy: .bufferingNewest(256))
    }

    deinit {
        inboundTask?.cancel()
        watchdogTask?.cancel()
        retryTask?.cancel()
        pumpTask?.cancel()
        connection?.close()
        eventSink.finish()
    }

    // MARK: - Control

    public func start() {
        guard phase == .idle else { return }
        failures = 0
        setupTimeoutsInARow = 0
        connect()
    }

    public func stop() {
        guard phase != .idle else { return }
        endConnection()
        phase = .idle
        lostAt = nil
        eventSink.yield(.disconnected(.stopped))
    }

    // MARK: - Sending. Dropped unless connected, and never queued without bound.

    public func sendAudio(_ pcm: Data) {
        guard phase == .ready, micUplink, !pcm.isEmpty else { return }
        queue.enqueueAudio(pcm)
        wakePump()
    }

    public func sendAudioStreamEnd() {
        guard phase == .ready, micUplink else { return }
        speechEndAt = clock()
        awaitingToolCall = true
        awaitingModelAudio = true
        queue.enqueueAudioStreamEnd()
        wakePump()
    }

    /// Latest wins. The caller owns the rate, which the docs cap at 1 per second.
    public func sendFrame(_ jpeg: Data) {
        guard phase == .ready, frameUplink, !jpeg.isEmpty else { return }
        queue.enqueueFrame(jpeg)
        wakePump()
    }

    /// Kept even while disconnected, because a fresh connection rebuilds context from it.
    public func sendStateBrief(_ brief: StateBrief) {
        if let latestBrief, brief.version < latestBrief.version { return }
        latestBrief = brief
        guard phase == .ready else { return }
        queue.enqueueBrief(brief, seed: false)
        wakePump()
    }

    /// Dropped unless connected, since a cue about what was just said is no use later.
    public func sendKick() {
        guard phase == .ready else { return }
        queue.enqueueKick()
        wakePump()
    }

    /// Backstop for invariant 11: whatever the callers do, nothing goes up once the policy closes.
    public func applyPolicy(_ policy: RuntimePolicy) {
        if micUplink, !policy.micUplink {
            queue.clearAudio()
            // The docs ask for this when the stream pauses, so the server stops waiting for speech.
            if phase == .ready { queue.enqueueAudioStreamEnd() }
            wakePump()
        }
        if !policy.frameUplink { queue.clearFrame() }
        micUplink = policy.micUplink
        frameUplink = policy.frameUplink
    }

    // MARK: - Connection lifecycle

    private func connect() {
        let request = RealtimeConnectRequest(
            resumeHandle: resumeHandle,
            seedsHistory: resumeHandle == nil && latestBrief != nil
        )
        currentRequest = request
        connectStartedAt = clock()
        phase = .connecting

        let generation = self.generation
        let connection = transport.connect(request)
        self.connection = connection

        inboundTask = Task { [weak self] in
            for await message in connection.inbound {
                await self?.handle(message, generation: generation)
            }
            await self?.inboundEnded(generation: generation)
        }
        let timeout = Self.backoffDelay(failures: setupTimeoutsInARow + 1, schedule: configuration.setupTimeouts)
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.setupTimedOut(generation: generation)
        }
    }

    private func setupTimedOut(generation: Int) {
        guard generation == self.generation, phase == .connecting else { return }
        setupTimeoutsInARow += 1
        connectionLost(.setupTimeout)
    }

    private func inboundEnded(generation: Int) {
        guard generation == self.generation else { return }
        connectionLost(.networkFailure(code: nil))
    }

    private func connectionLost(_ reason: LiveDisconnectReason) {
        guard phase == .connecting || phase == .ready else { return }
        let now = clock()
        let stable = phase == .ready && now - readyAt >= configuration.stableConnectionSeconds
        endConnection()
        if lostAt == nil { lostAt = now }
        eventSink.yield(.disconnected(reason))

        if reason == .invalidConfiguration {
            phase = .idle
            return
        }
        if stable { failures = 0 }
        if reason == .goAway {
            // A planned move resumes straight away, unless the server keeps asking for one.
            if stable {
                scheduleRetry(after: 0)
                return
            }
        } else if !stable {
            // A connection that didn't last suggests the session itself is bad, and a resume can
            // keep failing, so the next try starts fresh from the latest brief.
            resumeHandle = nil
        }
        failures += 1
        scheduleRetry(after: Self.backoffDelay(failures: failures, schedule: configuration.backoff))
    }

    static func backoffDelay(failures: Int, schedule: [TimeInterval]) -> TimeInterval {
        guard let last = schedule.last else { return 1 }
        return failures <= schedule.count ? schedule[max(failures - 1, 0)] : last
    }

    private func scheduleRetry(after delay: TimeInterval) {
        phase = .waitingToRetry
        let generation = self.generation
        retryTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.retry(generation: generation)
        }
    }

    private func retry(generation: Int) {
        guard generation == self.generation, phase == .waitingToRetry else { return }
        connect()
    }

    private func endConnection() {
        generation += 1
        inboundTask?.cancel()
        watchdogTask?.cancel()
        retryTask?.cancel()
        pumpTask?.cancel()
        inboundTask = nil
        watchdogTask = nil
        retryTask = nil
        pumpTask = nil
        connection?.close()
        connection = nil
        queue.removeAll()
        speechEndAt = nil
    }

    // MARK: - Inbound

    private func handle(_ message: RealtimeInbound, generation: Int) {
        guard generation == self.generation else { return }
        switch message {
        case .ready:
            becameReady()
        case let .audio(data):
            markFirst(&awaitingModelAudio, .speechEndToModelAudio)
            eventSink.yield(.modelAudio(data))
        case .interrupted:
            eventSink.yield(.interrupted)
        case .turnComplete:
            eventSink.yield(.turnComplete)
        case let .inputTranscript(text):
            eventSink.yield(.inputTranscript(text))
        case let .outputTranscript(text):
            eventSink.yield(.outputTranscript(text))
        case let .functionCalls(calls):
            handle(calls)
        case .functionCallsCancelled:
            // Each call was answered and reported on arrival, so there is nothing left to cancel,
            // and the engine has already judged the observation.
            break
        case let .resumption(handle, resumable):
            // When not resumable the new handle is empty, and the older one still works with some
            // loss, so it stays.
            if resumable, let handle, !handle.isEmpty { resumeHandle = handle }
        case let .usage(usage):
            eventSink.yield(.usage(usage))
        case .goAway:
            connectionLost(.goAway)
        case let .closed(reason):
            connectionLost(reason)
        }
    }

    private func becameReady() {
        guard phase == .connecting else { return }
        watchdogTask?.cancel()
        watchdogTask = nil
        phase = .ready
        setupTimeoutsInARow = 0
        let now = clock()
        readyAt = now
        eventSink.yield(.timing(.setup, seconds: now - connectStartedAt))
        if let lostAt {
            eventSink.yield(.timing(.reconnectGap, seconds: now - lostAt))
            self.lostAt = nil
        }
        eventSink.yield(.connected(resumed: currentRequest.resumeHandle != nil))
        // Context comes from the engine's latest brief, never from transcripts. A resumed session
        // gets it too, since state may have moved on during the gap.
        if let latestBrief {
            queue.enqueueBrief(latestBrief, seed: currentRequest.seedsHistory)
            wakePump()
        }
    }

    private func handle(_ calls: [RealtimeFunctionCall]) {
        markFirst(&awaitingToolCall, .speechEndToToolCall)
        var responses: [ToolResponse] = []
        for call in calls {
            let routed = router.route(call)
            if let proposal = routed.proposal { eventSink.yield(.proposal(proposal)) }
            if let scene = routed.scene { eventSink.yield(.scene(scene)) }
            if let press = routed.press { eventSink.yield(.press(press)) }
            if let response = routed.response { responses.append(response) }
        }
        if !responses.isEmpty {
            queue.enqueueToolResponses(responses)
            wakePump()
        }
    }

    private func markFirst(_ awaiting: inout Bool, _ metric: LiveTimingMetric) {
        guard awaiting, let speechEndAt else { return }
        awaiting = false
        eventSink.yield(.timing(metric, seconds: clock() - speechEndAt))
    }

    // MARK: - Outbound pump

    /// Sending happens here, away from the callers, so a slow socket never holds them up.
    private func wakePump() {
        guard phase == .ready, pumpTask == nil, !queue.isEmpty, let connection else { return }
        let generation = self.generation
        pumpTask = Task { [weak self] in
            await self?.drain(connection, generation: generation)
        }
    }

    private func drain(_ connection: any RealtimeConnection, generation: Int) async {
        while generation == self.generation, let next = queue.next() {
            do {
                try await connection.send(next)
            } catch {
                // Only the fact matters. The error's text can hold the URL, so it goes no further.
                if generation == self.generation { connectionLost(.sendFailed) }
                return
            }
        }
        if generation == self.generation { pumpTask = nil }
    }
}
