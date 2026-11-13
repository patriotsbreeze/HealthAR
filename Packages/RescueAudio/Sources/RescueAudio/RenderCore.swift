import Synchronization

/// Everything the audio thread touches. Holds only pointers and integers, so render callbacks
/// capture it by value and can't touch a reference count, allocate, or take a lock.
struct RenderCore: @unchecked Sendable {
    /// The metronome source runs at this rate whatever the hardware does, and the mixer resamples.
    /// One fixed rate means a route change can't disturb the sample counter.
    static let clickSampleRate = 48_000
    static let voiceSampleRate = 24_000

    private struct MetronomeState {
        var generator: ClickGenerator
        var wasOn = false
    }

    let micRing: SPSCRingBuffer
    let phraseRing: SPSCRingBuffer
    let readAloudRing: SPSCRingBuffer
    let modelRing: SPSCRingBuffer

    private let metronome: UnsafeMutablePointer<MetronomeState>
    private let metronomeOn: UnsafeMutablePointer<Atomic<Bool>>
    private let muted: UnsafeMutablePointer<Atomic<Bool>>
    private let modelHeld: UnsafeMutablePointer<Atomic<Bool>>
    private let renderCalls: UnsafeMutablePointer<Atomic<Int>>

    init() {
        // About 340 ms at 48 kHz, which bounds uplink latency if the drain stalls.
        micRing = SPSCRingBuffer(capacity: 1 << 14)
        // The local lanes are refilled every 20 ms, so about 5 s is plenty.
        phraseRing = SPSCRingBuffer(capacity: 1 << 17)
        readAloudRing = SPSCRingBuffer(capacity: 1 << 17)
        // About 43 s, longer than the 20 s runaway limit, so only the gate limits a turn.
        modelRing = SPSCRingBuffer(capacity: 1 << 20)

        metronome = .allocate(capacity: 1)
        metronome.initialize(to: MetronomeState(generator: ClickGenerator(sampleRate: Self.clickSampleRate)))
        metronomeOn = .allocate(capacity: 1)
        metronomeOn.initialize(to: Atomic(false))
        muted = .allocate(capacity: 1)
        muted.initialize(to: Atomic(false))
        modelHeld = .allocate(capacity: 1)
        modelHeld.initialize(to: Atomic(false))
        renderCalls = .allocate(capacity: 1)
        renderCalls.initialize(to: Atomic(0))
    }

    func deallocate() {
        for ring in [micRing, phraseRing, readAloudRing, modelRing] { ring.deallocate() }
        metronome.deinitialize(count: 1)
        metronome.deallocate()
        metronomeOn.deinitialize(count: 1)
        metronomeOn.deallocate()
        muted.deinitialize(count: 1)
        muted.deallocate()
        modelHeld.deinitialize(count: 1)
        modelHeld.deallocate()
        renderCalls.deinitialize(count: 1)
        renderCalls.deallocate()
    }

    // MARK: - Any thread

    func setMetronome(on: Bool) {
        metronomeOn.pointee.store(on, ordering: .relaxed)
    }

    func setMuted(_ value: Bool) {
        muted.pointee.store(value, ordering: .relaxed)
    }

    /// Model audio stays in its ring. The phrase ring can run dry between two phrases, and a word of
    /// the answer mustn't come through the gap.
    func setModelHeld(_ value: Bool) {
        modelHeld.pointee.store(value, ordering: .relaxed)
    }

    /// Stops changing when the audio hardware stops calling back, whatever the reason.
    var renderCallCount: Int { renderCalls.pointee.load(ordering: .relaxed) }

    // MARK: - Render thread only

    /// Returns true when the output is silent.
    func renderMetronome(into output: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        renderCalls.pointee.wrappingAdd(1, ordering: .relaxed)
        guard metronomeOn.pointee.load(ordering: .relaxed) else {
            metronome.pointee.wasOn = false
            output.update(repeating: 0, count: frames)
            return true
        }
        // Starting fresh puts the first click in this very buffer.
        if !metronome.pointee.wasOn {
            metronome.pointee.wasOn = true
            metronome.pointee.generator.reset()
        }
        // Rendered even when muted, so the beat is exactly where it should be on resume.
        metronome.pointee.generator.render(into: output, frameCount: frames)
        guard !muted.pointee.load(ordering: .relaxed) else {
            output.update(repeating: 0, count: frames)
            return true
        }
        return false
    }

    /// Local phrases come first, then Read Aloud, then model audio. Returns true when silent.
    func renderVoice(into output: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        // While muted nothing is consumed, so a required phrase waits rather than going unheard.
        guard !muted.pointee.load(ordering: .relaxed) else {
            output.update(repeating: 0, count: frames)
            return true
        }
        var filled = phraseRing.pop(into: output, count: frames)
        if filled < frames { filled += readAloudRing.pop(into: output + filled, count: frames - filled) }
        if filled < frames, !modelHeld.pointee.load(ordering: .relaxed) {
            filled += modelRing.pop(into: output + filled, count: frames - filled)
        }
        if filled < frames { (output + filled).update(repeating: 0, count: frames - filled) }
        return filled == 0
    }

    func captureMic(_ input: UnsafePointer<Float>, frames: Int) {
        micRing.push(input, count: frames)
    }
}
