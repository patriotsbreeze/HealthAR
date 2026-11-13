import Foundation

/// Push-to-talk questions, answered by a live model that can only read measurements.
///
/// The session declares exactly one tool to the model and routes every tool call through the
/// Conductor. It cannot start, stop or change anything in the app: its whole output is the event
/// stream. Coaching never depends on it, so when the connection drops it says so and stops.
public actor VoiceSession {
    /// What happens in the session, in order. The stream lives as long as the session object.
    public nonisolated let events: AsyncStream<VoiceEvent>

    private enum Phase {
        case idle, connecting, ready
    }

    private enum Command: Sendable {
        case begin
        case audio(Data)
        case end
    }

    private let apiKey: String
    private let socketFactory: RealtimeSocketFactory
    private let conductor: Conductor
    private let config: AgentsConfig
    private let emitter: AsyncStream<VoiceEvent>.Continuation
    private let commands: AsyncStream<Command>.Continuation

    private var phase = Phase.idle
    /// Counts connections, so a late callback from an old one can be recognised and ignored.
    private var generation = 0
    private var socket: (any RealtimeSocket)?
    private var reader: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    /// Tool calls still running, by call id. A cancelled call is removed, and so gets no answer.
    private var toolRuns: [String: Task<Void, Never>] = [:]
    private var callsWithoutID = 0
    private var talking = false

    /// - Parameters:
    ///   - apiKey: supplied by the app. Sent only as a header on the socket handshake.
    ///   - socketFactory: makes the socket for a handshake request.
    ///   - conductor: runs the tool calls. Register `GetCPRQuality` on it before connecting.
    public init(apiKey: String, socketFactory: @escaping RealtimeSocketFactory, conductor: Conductor,
                config: AgentsConfig = AgentsConfig()) {
        self.apiKey = apiKey
        self.socketFactory = socketFactory
        self.conductor = conductor
        self.config = config
        let (events, emitter) = AsyncStream<VoiceEvent>.makeStream()
        self.events = events
        self.emitter = emitter
        // Talking and audio arrive from any thread, the audio thread included. One queue with one
        // reader keeps start, audio and end in the order they happened.
        let (inbox, commands) = AsyncStream<Command>.makeStream()
        self.commands = commands
        Task { [weak self] in
            for await command in inbox {
                await self?.handle(command)
            }
        }
    }

    deinit {
        commands.finish()
        emitter.finish()
        reader?.cancel()
        watchdog?.cancel()
        toolRuns.values.forEach { $0.cancel() }
        socket?.close()
    }

    /// Opens the socket and sends the setup. `.connected` follows once the service accepts it;
    /// `.failed` then `.disconnected` follow if it does not. Does nothing when already connected.
    public func connect() async {
        guard phase == .idle else { return }
        let setup = WireFormat.setup(config: config, system: VoicePrompt.system,
                                     toolName: GetCPRQuality.name, toolDescription: VoicePrompt.toolDescription)
        guard let request = WireFormat.handshake(apiKey: apiKey, timeout: config.voiceSetupTimeout),
              let setupText = try? String(decoding: setup.encoded(), as: UTF8.self) else {
            emit(.failed(reason: "The voice session could not be set up."))
            return
        }
        phase = .connecting
        generation += 1
        let mine = generation
        let socket = socketFactory(request)
        self.socket = socket
        do {
            try await socket.connect()
            try await socket.send(text: setupText)
        } catch {
            if mine == generation {
                end(reason: "Could not reach the voice service. \(describe(error))", failed: true)
            }
            return
        }
        // disconnect() may have run while the socket was opening.
        guard mine == generation else { return }

        reader = Task { [weak self] in
            var ending = "The voice service closed the connection."
            do {
                for try await frame in socket.frames() {
                    await self?.receive(frame, generation: mine)
                }
            } catch {
                ending = self?.describe(error) ?? ending
            }
            await self?.dropped(reason: ending, generation: mine)
        }
        let patience = config.voiceSetupTimeout
        watchdog = Task { [weak self] in
            do {
                try await Task.sleep(for: patience)
            } catch {
                return
            }
            await self?.setupOverdue(generation: mine)
        }
    }

    /// Closes the session. `.disconnected` follows. Does nothing when not connected.
    public func disconnect() {
        guard phase != .idle else { return }
        end(reason: "Closed by the app.")
    }

    /// The person pressed the talk button. Opens a turn. Safe to call from any thread.
    public nonisolated func beginTalking() {
        commands.yield(.begin)
    }

    /// Microphone audio: 16 kHz, 16-bit, mono, little-endian. Audio outside a held turn is dropped
    /// here and never leaves the phone. Safe to call from any thread.
    public nonisolated func sendAudio(pcm16k: Data) {
        commands.yield(.audio(pcm16k))
    }

    /// The person released the talk button. Closes the turn so the model answers. Safe to call
    /// from any thread.
    public nonisolated func endTalking() {
        commands.yield(.end)
    }

    // MARK: - Talking

    private func handle(_ command: Command) async {
        switch command {
        case .begin:
            guard phase == .ready else {
                emit(.failed(reason: "Not connected to the voice service, so nothing was sent."))
                return
            }
            guard !talking else { return }
            talking = true
            await send(WireFormat.activityStart)
        case .audio(let pcm):
            guard phase == .ready, talking, !pcm.isEmpty else { return }
            await send(WireFormat.audio(pcm))
        case .end:
            guard phase == .ready, talking else { return }
            talking = false
            await send(WireFormat.activityEnd)
        }
    }

    // MARK: - Messages from the service

    private func receive(_ frame: SocketFrame, generation: Int) {
        guard generation == self.generation, let signals = WireFormat.signals(in: frame) else { return }
        for signal in signals {
            switch signal {
            case .setupComplete:
                guard phase == .connecting else { continue }
                phase = .ready
                watchdog?.cancel()
                watchdog = nil
                emit(.connected)
            case .heard(let text):
                emit(.heard(text: text))
            case .replied(let text):
                emit(.replied(text: text))
            case .audio(let pcm):
                emit(.speaking(pcm24k: pcm))
            case .turnComplete:
                emit(.turnEnded)
            case .toolCall(let id, let name, let argumentsJSON):
                startTool(id: id, name: name, argumentsJSON: argumentsJSON)
            case .toolCallsCancelled(let ids):
                for id in ids {
                    toolRuns.removeValue(forKey: id)?.cancel()
                }
            }
        }
    }

    // MARK: - Tools

    private func startTool(id: String?, name: String, argumentsJSON: Data) {
        emit(.toolCalled(name: Scrubber.label(name)))
        callsWithoutID += id == nil ? 1 : 0
        let key = id ?? "without-id-\(callsWithoutID)"
        let mine = generation
        let conductor = self.conductor
        // Run apart from the reader, so a cancellation from the service can arrive while it runs.
        toolRuns[key] = Task { [weak self] in
            let outcome = await conductor.call(name: name, argumentsJSON: argumentsJSON)
            await self?.finishTool(key: key, id: id, name: name, outcome: outcome, generation: mine)
        }
    }

    private func finishTool(key: String, id: String?, name: String, outcome: ToolOutcome, generation: Int) async {
        guard generation == self.generation, toolRuns.removeValue(forKey: key) != nil else { return }
        if let json = outcome.resultJSON, let result = try? JSONValue(parsing: json) {
            await send(WireFormat.toolResult(id: id, name: name, result: result))
        } else {
            await send(WireFormat.toolError(id: id, name: name, reason: outcome.sentence))
        }
    }

    // MARK: - Connection

    private func send(_ message: JSONValue) async {
        guard let socket, let data = try? message.encoded() else { return }
        let mine = generation
        do {
            try await socket.send(text: String(decoding: data, as: UTF8.self))
        } catch {
            dropped(reason: describe(error), generation: mine)
        }
    }

    private func setupOverdue(generation: Int) {
        guard generation == self.generation, phase == .connecting else { return }
        end(reason: "The voice service did not answer in time.", failed: true)
    }

    private func dropped(reason: String, generation: Int) {
        guard generation == self.generation, phase != .idle else { return }
        // A drop before the service accepted the setup is a failed connection, not a lost one.
        end(reason: reason, failed: phase == .connecting)
    }

    /// Ends the current connection for good. There is no automatic reconnect.
    private func end(reason: String, failed: Bool = false) {
        generation += 1
        phase = .idle
        talking = false
        reader?.cancel()
        reader = nil
        watchdog?.cancel()
        watchdog = nil
        toolRuns.values.forEach { $0.cancel() }
        toolRuns.removeAll()
        socket?.close()
        socket = nil
        if failed {
            emit(.failed(reason: reason))
        }
        emit(.disconnected(reason: reason))
    }

    private func emit(_ event: VoiceEvent) {
        emitter.yield(event)
    }

    /// A socket error in plain words, with the key removed and the length capped.
    private nonisolated func describe(_ error: Error) -> String {
        if let closure = error as? SocketClosure {
            let reason = Scrubber.clean(closure.reason, secret: apiKey, limit: config.errorDetailLimit)
            let ending = reason.isEmpty ? "." : ": \(reason)"
            return "The voice service closed the connection with code \(closure.code)\(ending)"
        }
        let detail = Scrubber.clean(error.localizedDescription, secret: apiKey, limit: config.errorDetailLimit)
        return "The connection to the voice service was lost: \(detail)"
    }
}
