#if os(iOS)
import AVFoundation
import Synchronization

/// On-device speech for text that has no clip, so a required step is never silent.
///
/// First it renders into buffers, because audio inside the engine shares its echo cancellation,
/// mute, and priority rules, and voice processing ducks anything outside it. If that yields nothing
/// it speaks directly through the system. `begin`, `warmUp`, `checkTimeouts`, and `handler` all run
/// on the controller's queue.
final class SpeechRenderer: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case samples([Float])
        case finished
        case failed
    }

    private enum Phase {
        case idle
        case writing(lastActivity: DispatchTime, hasAudio: Bool)
        case speaking(utterance: ObjectIdentifier, deadline: DispatchTime)
    }

    private static let firstAudioTimeout = 3.0
    private static let stallTimeout = 1.5

    private let queue: DispatchQueue
    private let handler: @Sendable (Event) -> Void
    private var phase = Phase.idle
    private var text = ""

    // The first use of a voice blocked its caller for over 30 s on a fresh Simulator boot. Every
    // synthesizer call runs here, so a stall delays this speech and nothing else.
    private let synthesisQueue = DispatchQueue(label: "rescue.audio.speech", qos: .userInitiated)
    private lazy var synthesizer: AVSpeechSynthesizer = {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        return synthesizer
    }()
    /// Lets work that has waited out a stall see that it's no longer wanted.
    private let currentRequest = Atomic<Int>(0)

    init(queue: DispatchQueue, handler: @escaping @Sendable (Event) -> Void) {
        self.queue = queue
        self.handler = handler
    }

    /// Loads the voice ahead of time, because the first utterance otherwise starts slowly.
    func warmUp() {
        synthesisQueue.async {
            let utterance = AVSpeechUtterance(string: "OK")
            utterance.voice = Self.voice()
            self.synthesizer.write(utterance) { _ in }
        }
    }

    func begin(text: String) {
        self.text = text
        let request = nextRequest()
        phase = .writing(lastActivity: .now(), hasAudio: false)
        synthesisQueue.async {
            guard self.isCurrent(request) else { return }
            let converter = VoiceBufferConverter()
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = Self.voice()
            // Buffers arrive on the main thread, and may be reused after this returns.
            self.synthesizer.write(utterance) { [weak self] buffer in
                guard let self else { return }
                let pcm = buffer as? AVAudioPCMBuffer
                let samples = pcm.map(converter.convert) ?? []
                let ended = (pcm?.frameLength ?? 0) == 0
                self.queue.async { self.received(samples, ended: ended, request: request) }
            }
        }
    }

    /// Abandons this request. Anything still arriving from it is ignored, and nothing is reported.
    func cancel() {
        let request = nextRequest()
        phase = .idle
        synthesisQueue.async {
            guard self.isCurrent(request) else { return }
            self.synthesizer.stopSpeaking(at: .immediate)
        }
    }

    /// The system doesn't always signal the end of a write, or anything at all, so the caller polls.
    func checkTimeouts() {
        let now = DispatchTime.now()
        switch phase {
        case .idle:
            break
        case let .writing(lastActivity, hasAudio):
            if hasAudio {
                if now > lastActivity + Self.stallTimeout { finish(.finished) }
            } else if now > lastActivity + Self.firstAudioTimeout {
                speakDirectly()
            }
        case let .speaking(_, deadline):
            if now > deadline {
                let request = nextRequest()
                synthesisQueue.async {
                    guard self.isCurrent(request) else { return }
                    self.synthesizer.stopSpeaking(at: .immediate)
                }
                finish(.failed)
            }
        }
    }

    private func received(_ samples: [Float], ended: Bool, request: Int) {
        guard isCurrent(request), case let .writing(_, hadAudio) = phase else { return }
        let hasAudio = hadAudio || !samples.isEmpty
        phase = .writing(lastActivity: .now(), hasAudio: hasAudio)
        if !samples.isEmpty { handler(.samples(samples)) }
        guard ended else { return }
        if hasAudio {
            finish(.finished)
        } else {
            speakDirectly()
        }
    }

    private func speakDirectly() {
        let request = nextRequest()
        // Handed over to the synthesis queue, and only its identity is used here afterward.
        nonisolated(unsafe) let utterance = AVSpeechUtterance(string: text)
        let allowance = 5 + 0.15 * Double(text.count)
        phase = .speaking(utterance: ObjectIdentifier(utterance), deadline: .now() + allowance)
        synthesisQueue.async {
            guard self.isCurrent(request) else { return }
            utterance.voice = Self.voice()
            self.synthesizer.stopSpeaking(at: .immediate)
            self.synthesizer.speak(utterance)
        }
    }

    private func finish(_ event: Event) {
        phase = .idle
        handler(event)
    }

    private func nextRequest() -> Int {
        currentRequest.add(1, ordering: .relaxed).newValue
    }

    private func isCurrent(_ request: Int) -> Bool {
        currentRequest.load(ordering: .relaxed) == request
    }

    private static func voice() -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: "en-US")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        directSpeechEnded(ObjectIdentifier(utterance))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        directSpeechEnded(ObjectIdentifier(utterance))
    }

    // Stopping a write also cancels, and that report arrives later, so match on the utterance.
    private func directSpeechEnded(_ utterance: ObjectIdentifier) {
        queue.async {
            guard case let .speaking(current, _) = self.phase, current == utterance else { return }
            self.finish(.finished)
        }
    }
}
#endif
