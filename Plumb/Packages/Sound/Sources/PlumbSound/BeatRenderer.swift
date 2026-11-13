import AVFoundation
import Synchronization

/// What the audio thread runs for every block of output.
///
/// It reads and writes atomics and does arithmetic, nothing else: no allocation, no lock, no
/// call that could wait. Everything it needs was worked out before the engine started.
struct BeatRenderer: Sendable {
    private let synth: ClickSynth
    private let clock: BeatClock
    private let hostClock: HostClock
    private let duckedGain: Float
    /// Largest change in gain from one sample to the next.
    private let gainStep: Float

    init(synth: ClickSynth, clock: BeatClock, hostClock: HostClock, config: BeatEngine.Config) {
        self.synth = synth
        self.clock = clock
        self.hostClock = hostClock
        duckedGain = Float(config.duckedGain)
        gainStep = Float(1 / max(1, config.duckRampSeconds * config.sampleRate))
    }

    /// Fills the output with the next `frameCount` samples of the beat and moves the clock on.
    func render(frameCount: Int, timestamp: UnsafePointer<AudioTimeStamp>,
                into list: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard buffers.count > 0, let output = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
            return
        }

        var frame = Int(clock.nextFrame.load(ordering: .relaxed))
        let duckUntil = Int(clock.duckUntilFrame.load(ordering: .relaxed))
        var isTock = clock.clickIsTock.load(ordering: .relaxed)
        var sounds = clock.clickSounds.load(ordering: .relaxed)
        var gain = clock.gain.load(ordering: .relaxed)
        noteAnchor(firstFrame: frame, timestamp: timestamp)

        for index in 0..<frameCount {
            let offset = synth.position(ofSample: frame).offset
            // A click is decided whole, on its first sample: its timbre and whether it sounds.
            // So a change of mind never cuts a click in half or starts one half-way through.
            if offset == 0 {
                isTock = clock.reached.load(ordering: .relaxed)
                sounds = clock.audible.load(ordering: .relaxed)
            }
            let target: Float = frame < duckUntil ? duckedGain : 1
            gain = target > gain ? min(target, gain + gainStep) : max(target, gain - gainStep)
            output[index] = sounds ? synth.click(offset: offset, timbre: isTock ? .tock : .tick) * gain : 0
            frame += 1
        }

        // The format is mono, but if the system ever asks for more channels they all get the beat.
        for channel in 1..<max(1, buffers.count) {
            buffers[channel].mData?.assumingMemoryBound(to: Float.self).update(from: output, count: frameCount)
        }

        clock.nextFrame.store(Int64(frame), ordering: .relaxed)
        clock.clickIsTock.store(isTock, ordering: .relaxed)
        clock.clickSounds.store(sounds, ordering: .relaxed)
        clock.gain.store(gain, ordering: .relaxed)
    }

    /// Notes when sample 0 left for the output, so the main thread can tell which sample is heard now.
    private func noteAnchor(firstFrame: Int, timestamp: UnsafePointer<AudioTimeStamp>) {
        let hostTimeValid = timestamp.pointee.mFlags.rawValue & AudioTimeStampFlags.hostTimeValid.rawValue != 0
        let anchor = hostTimeValid
            ? hostClock.seconds(ticks: timestamp.pointee.mHostTime) - Double(firstFrame) / synth.sampleRate
            : Double.nan
        clock.anchorSeconds.store(anchor, ordering: .relaxed)
    }
}
