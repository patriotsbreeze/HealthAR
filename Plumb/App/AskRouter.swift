import AVFoundation
import PlumbAgents
import PlumbContracts
import PlumbSession
import Speech

/// "Hold to ask". Each press goes to the live voice when a key is configured, the network is up and the
/// voice service's connection is open, and otherwise to the phone's own path, which needs none of them:
/// the question is turned into text on the phone, sorted into one of a few fixed kinds, and answered with
/// a fixed sentence filled in from the measurements. No model ever writes the words said back on that path.
///
/// The way is chosen when the button goes down and kept until it comes up, and the two ways have
/// separate microphones, so a press never starts one while the other is still listening or answering.
@MainActor
final class AskRouter {
    /// Writes one line to the session log at the current session time.
    var record: (LogEntry.Source, LogEntry.Body) -> Void = { _, _ in }
    /// Says the phone's own answer out loud, under the cues.
    var speak: (String) -> Void = { _ in }

    private let agents: AgentsHub?
    private let network = NetworkWatch()
    private var latest = WorldDigestBuilder.unknown
    private var pressed: AskRoute?
    /// Answers on the phone's own path still being worked out: one from each release until its answer is ready.
    private var answersPending = 0
    /// One more on every `cancel`, so an answer worked out for a press from before it is not said.
    private var generation = 0
    private var askingPermission = false
    private lazy var offline = OfflineAsk(read: { [weak self] in
        await self?.digest() ?? WorldDigestBuilder.unknown
    })

    /// - Parameter agents: the live voice, or nil when the app was built without a key.
    init(agents: AgentsHub?) {
        self.agents = agents
    }

    /// Keeps the newest measurements for the phone's own answers. Called on every tick.
    func publish(metrics: Metrics, now: TimeInterval) {
        latest = WorldDigestBuilder.make(metrics: metrics, now: now)
    }

    private func digest() -> WorldDigest {
        latest
    }

    /// Gets the phone's own listening ready, fetching its speech model if it has none, so questions can
    /// later be heard without the network. Waits until speech permission has been asked for, because
    /// getting ready can ask for it, and it is asked for only on a press, alongside the microphone.
    func prepare() async {
        guard SFSpeechRecognizer.authorizationStatus() != .notDetermined else { return }
        if case .unavailable(let reason) = await offline.prepare() {
            record(.system, .note("Questions cannot be heard without the network yet. \(reason)"))
        }
    }

    /// The button went down (true) or came up (false).
    func changed(_ isPressed: Bool) {
        if isPressed { press() } else { release() }
    }

    /// True from the release of a press on the phone's own path until its answer is ready.
    private var answering: Bool { answersPending > 0 }

    private func press() {
        guard pressed == nil, permitted() else { return }
        let voiceReady = agents?.isVoiceReady == true
        let route = AskRoute.choose(isOnline: network.isOnline, hasKey: agents != nil, voiceConnected: voiceReady)
        // Online with a key but the voice's connection not open, as after it dropped: the phone answers this
        // press, and the connection is opened again for the next one.
        if route == .onDevice, network.isOnline, let agents, !voiceReady { agents.warmUp() }
        switch route {
        case .live:
            // The phone's own answer to the last question would play into the live reply.
            guard let agents, !offline.isListening, !answering, agents.beginAsking() else {
                if answering { record(.system, .note("Still working on the last question.")) }
                return
            }
        case .onDevice:
            guard !answering, agents?.microphoneInUse != true else {
                record(.system, .note("Still working on the last question."))
                return
            }
            do {
                try offline.begin()
            } catch {
                record(.system, .note(Self.words(for: error)))
                return
            }
        }
        pressed = route
    }

    private func release() {
        guard let route = pressed else { return }
        pressed = nil
        switch route {
        case .live:
            agents?.endAsking()
        case .onDevice:
            answersPending += 1
            let asked = generation
            Task { [weak self] in
                guard let self else { return }
                let result = await self.offline.end()
                self.answersPending -= 1
                // Cancelled meanwhile, as by the hand over: nothing late is said.
                guard asked == self.generation else { return }
                for line in result.logLines { self.record(line.source, line.body) }
                self.speak(result.answer)
            }
        }
    }

    /// Ends whatever is under way without an answer: a press whose release may never come, because the
    /// button went away or the app left the screen, and any answer still being worked out. The microphone
    /// stops. Safe to call at any time.
    func cancel() {
        generation += 1
        guard let route = pressed else { return }
        pressed = nil
        switch route {
        case .live:
            agents?.endAsking()
        case .onDevice:
            answersPending += 1
            Task { [weak self] in
                guard let self else { return }
                _ = await self.offline.end()
                self.answersPending -= 1
            }
        }
    }

    /// True when the microphone may be used. The first press asks for the microphone and for speech
    /// recognition together and does nothing else; the person holds again once they have answered.
    private func permitted() -> Bool {
        let microphone = AVAudioApplication.shared.recordPermission
        if microphone == .undetermined || SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            askPermission()
            return false
        }
        guard microphone == .granted else {
            record(.system, .note("Microphone not allowed. Turn it on in Settings to ask questions."))
            return false
        }
        return true
    }

    private func askPermission() {
        guard !askingPermission else { return }
        askingPermission = true
        Task { [weak self] in
            _ = await AVAudioApplication.requestRecordPermission()
            _ = await Self.speechPermission()
            guard let self else { return }
            self.askingPermission = false
            await self.prepare()
        }
    }

    /// Speech recognition permission, asking for it when it has not been asked yet.
    private nonisolated static func speechPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    /// Why listening on the phone could not start, in plain words.
    private static func words(for error: Error) -> String {
        switch error as? OnDeviceTranscriber.Failure {
        case .notReady(let reason): "Questions cannot be heard without the network yet. \(reason)"
        case .busy: "Still working on the last question."
        case .noInput: "Microphone could not start."
        case .unsupportedFormat: "The microphone's sound could not be read."
        case nil: "Microphone could not start."
        }
    }
}
