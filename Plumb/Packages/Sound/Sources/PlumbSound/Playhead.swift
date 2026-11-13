import Darwin

/// Reads the machine's tick counter as seconds, using only arithmetic so the audio thread may use it.
struct HostClock: Sendable {
    private let secondsPerTick: Double

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    /// A tick count from the audio system, as seconds.
    func seconds(ticks: UInt64) -> Double {
        Double(ticks) * secondsPerTick
    }

    /// The present moment, on the same scale.
    var now: Double {
        seconds(ticks: mach_absolute_time())
    }
}

/// Works out which beat sample is leaving the speaker now, as opposed to the one being generated.
///
/// The audio thread makes sound a block at a time and some milliseconds early. A visual that
/// followed the generated sample would move in jumps and run ahead of what is heard.
struct Playhead: Sendable {
    let sampleRate: Double
    /// Furthest the heard sample may trail the generated one.
    let maxLagFrames: Int64

    init(config: BeatEngine.Config) {
        sampleRate = config.sampleRate
        maxLagFrames = Int64((config.maxPlayheadLagSeconds * config.sampleRate).rounded())
    }

    /// The sample being heard at `nowSeconds`.
    /// - Parameters:
    ///   - generated: index of the next sample the audio thread will make.
    ///   - anchorSeconds: host time at which sample 0 was handed to the output; not a number if unknown.
    ///   - latencySeconds: delay between handing a sample to the output and hearing it.
    func heardFrame(generated: Int64, anchorSeconds: Double, nowSeconds: Double,
                    latencySeconds: Double) -> Int64 {
        // With no anchor (before the first block, or when rendering offline) the generated
        // sample is the best answer there is.
        guard anchorSeconds.isFinite else { return generated }
        let estimate = ((nowSeconds - anchorSeconds - latencySeconds) * sampleRate).rounded(.down)
        // Sound cannot be heard before it is made, and a clock that says it trails by more than
        // a moment is wrong; either way stay close to what was generated.
        let earliest = max(0, generated - maxLagFrames)
        return Int64(min(Double(generated), max(Double(earliest), estimate)))
    }
}
