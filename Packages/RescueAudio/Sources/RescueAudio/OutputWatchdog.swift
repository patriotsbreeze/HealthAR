import Foundation
import RescueCore

/// Render callbacks are the only proof that sound is flowing, whatever the session claims. This
/// catches every way audio can die, including ones that send no notification. Pure, so it can be
/// tested without an audio engine.
struct OutputWatchdog {
    enum Verdict: Equatable {
        case nothingToDo
        /// The first callback since the engine started.
        case confirmed
        /// No sound. `giveUpOnMic` means voice processing has had its chances, and the metronome
        /// matters more, so the next engine must run without the mic.
        case rebuild(giveUpOnMic: Bool)
    }

    static let timeout = 1.0
    /// Voice processing can take a while to deliver its first buffer, which isn't a failure.
    static let firstCallbackTimeoutWithMic = 2.0
    static let silentEnginesAllowedWithMic = 2

    private var lastCount = 0
    private var lastRender: TimeInterval = 0
    private var confirmed = false
    private var silentEnginesWithMic = 0

    /// A new engine, or none. Its callbacks are yet to be seen.
    mutating func engineStarted(at now: TimeInterval) {
        confirmed = false
        lastRender = now
    }

    /// The system took the audio away, so the running engine needs proving again.
    mutating func outputInterrupted() {
        confirmed = false
    }

    mutating func check(renderCount: Int, mode: AudioMode?, at now: TimeInterval) -> Verdict {
        if renderCount != lastCount {
            lastCount = renderCount
            lastRender = now
            guard !confirmed, mode != nil else { return .nothingToDo }
            confirmed = true
            // Playback running says nothing about whether the mic's engine works.
            if mode == .full { silentEnginesWithMic = 0 }
            return .confirmed
        }

        let withMic = mode == .full
        let allowance = withMic && !confirmed ? Self.firstCallbackTimeoutWithMic : Self.timeout
        guard now > lastRender + allowance else { return .nothingToDo }
        guard withMic else { return .rebuild(giveUpOnMic: false) }

        silentEnginesWithMic += 1
        guard silentEnginesWithMic >= Self.silentEnginesAllowedWithMic else { return .rebuild(giveUpOnMic: false) }
        // Left one short of the limit, so a mic retry that is also silent gives up straight away.
        silentEnginesWithMic = Self.silentEnginesAllowedWithMic - 1
        return .rebuild(giveUpOnMic: true)
    }
}
