import Synchronization

/// The few numbers the main thread and the audio thread share.
/// Each is a single atomic, so neither thread ever waits for the other.
final class BeatClock: Sendable {
    /// Index of the next beat sample the audio thread will make. Counts from 0 at every start.
    let nextFrame = Atomic<Int64>(0)
    /// Whether clicks should sound. Looked at on each click's first sample.
    let audible = Atomic<Bool>(true)
    /// Whether the last compression reached the line. Looked at on each click's first sample.
    let reached = Atomic<Bool>(false)
    /// The beat is ducked for every sample before this one.
    let duckUntilFrame = Atomic<Int64>(0)
    /// Host time in seconds at which sample 0 was handed to the output. Not a number while unknown.
    let anchorSeconds = Atomic<Double>(.nan)
    /// Seconds between handing a sample to the output and hearing it.
    let outputLatencySeconds = Atomic<Double>(0)

    // Carried by the audio thread from the end of one block to the start of the next.

    /// Whether the click now sounding is a tock.
    let clickIsTock = Atomic<Bool>(false)
    /// Whether the click now sounding is audible at all.
    let clickSounds = Atomic<Bool>(false)
    /// The beat's gain as of the last sample made, between the ducked gain and 1.
    let gain = Atomic<Float>(1)

    /// Puts the beat back at its first sample. Only called while the engine is stopped.
    func rewind() {
        nextFrame.store(0, ordering: .relaxed)
        duckUntilFrame.store(0, ordering: .relaxed)
        anchorSeconds.store(.nan, ordering: .relaxed)
        clickSounds.store(false, ordering: .relaxed)
        gain.store(1, ordering: .relaxed)
    }
}
