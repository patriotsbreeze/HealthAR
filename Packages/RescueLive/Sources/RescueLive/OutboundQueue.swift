import Foundation
import RescueCore

/// What waits to be sent. Every lane is bounded, so a stalled socket costs old data and never
/// memory or time. Tool responses and briefs go first, then audio, then the newest frame.
struct OutboundQueue {
    private var control: [RealtimeOutbound] = []
    private var audio: [RealtimeOutbound] = []
    private var audioBytes = 0
    private var frame: Data?

    private let maxAudioBytes: Int
    private static let maxControl = 16
    private static let maxAudioEntries = 64

    init(maxAudioBytes: Int) {
        self.maxAudioBytes = maxAudioBytes
    }

    var isEmpty: Bool { control.isEmpty && audio.isEmpty && frame == nil }

    mutating func enqueueAudio(_ pcm: Data) {
        audio.append(.audio(pcm))
        audioBytes += pcm.count
        trimAudio()
    }

    mutating func enqueueAudioStreamEnd() {
        if audio.last == .audioStreamEnd { return }
        audio.append(.audioStreamEnd)
        trimAudio()
    }

    private mutating func trimAudio() {
        while audio.count > 1, audioBytes > maxAudioBytes || audio.count > Self.maxAudioEntries {
            if case let .audio(dropped) = audio.removeFirst() { audioBytes -= dropped.count }
        }
    }

    mutating func enqueueFrame(_ jpeg: Data) {
        frame = jpeg
    }

    /// A queued brief is already out of date, so the newest replaces it. A seed always stays.
    mutating func enqueueBrief(_ brief: StateBrief, seed: Bool) {
        control.removeAll { if case .stateBrief(_, seed: false) = $0 { true } else { false } }
        appendControl(.stateBrief(brief, seed: seed))
    }

    mutating func enqueueToolResponses(_ responses: [ToolResponse]) {
        appendControl(.toolResponses(responses))
    }

    mutating func enqueueKick() {
        appendControl(.kick)
    }

    private mutating func appendControl(_ message: RealtimeOutbound) {
        control.append(message)
        if control.count > Self.maxControl { control.removeFirst() }
    }

    mutating func clearAudio() {
        audio = []
        audioBytes = 0
    }

    mutating func clearFrame() {
        frame = nil
    }

    mutating func removeAll() {
        control = []
        clearAudio()
        clearFrame()
    }

    mutating func next() -> RealtimeOutbound? {
        if !control.isEmpty { return control.removeFirst() }
        if !audio.isEmpty {
            let message = audio.removeFirst()
            if case let .audio(pcm) = message { audioBytes -= pcm.count }
            return message
        }
        if let frame {
            self.frame = nil
            return .frame(jpeg: frame)
        }
        return nil
    }
}
