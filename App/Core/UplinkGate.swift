import Foundation
import RescueCore
import Synchronization

/// Everything that goes to the Live session, in order, on one consumer. Nothing here waits on the
/// session, so a slow socket can't hold up the audio queue or the main actor.
enum LiveCommand: Sendable {
    case start
    case stop
    case audio(Data)
    case audioEnd
    case frame(Data)
    case brief(StateBrief)
    case policy(RuntimePolicy)
    case kick
}

enum ModelAudioAdmission: Equatable {
    /// From a session that has been replaced. Nothing more from it matters.
    case stale
    case closed
    case played
}

/// The engine's current policy, readable from any thread, so every single send can check it
/// without touching the main actor. Closed until the engine has published a policy.
final class UplinkGate: Sendable {
    private struct State {
        var policy: RuntimePolicy?
        var bargeIn = false
        var commands: AsyncStream<LiveCommand>.Continuation?
        var session: Int?
        var clientBargeIn = true
    }

    private let state = Mutex(State())

    func setPolicy(_ policy: RuntimePolicy) {
        state.withLock { $0.policy = policy }
    }

    var micOpen: Bool { state.withLock { $0.policy?.micUplink ?? false } }
    var framesOpen: Bool { state.withLock { $0.policy?.frameUplink ?? false } }
    /// Single frozen frames to the one-shot locator. Never to the Live session, which only
    /// `framesOpen` lets through. Vision asks on the same terms.
    var locateOpen: Bool { state.withLock { $0.policy.map { $0.frameLocate || $0.frameUplink } ?? false } }
    /// One frame at a time to the scene read, on any step, so the live log runs the whole rescue. Shut
    /// with the mic: on a call, with the dispatcher open, or while the dispatcher was just heard, so
    /// nothing leaves the phone while someone else is on the line.
    var sceneReadOpen: Bool { state.withLock { $0.policy?.micUplink ?? false } }
    /// Towels, pillows and gloves: only where the step itself allows frozen frames to the locator.
    /// The uplink alone, as on the arrest path, opens this for the AED and nothing else.
    var materialsOpen: Bool { state.withLock { $0.policy?.frameLocate ?? false } }

    /// The server keeps sending a turn for a moment after the rescuer talks over it, and that tail
    /// must not play. Holds from the client's speech onset until the speech or the turn ends.
    var modelAudioOpen: Bool {
        state.withLock { ($0.policy?.modelSpeechOpen ?? false) && !$0.bargeIn }
    }

    func setBargeIn(_ active: Bool) {
        state.withLock { $0.bargeIn = active }
    }

    /// Speech onset. True means the model's audio should stop here. A chair scrape shouldn't cut an
    /// answer to someone awake, so there only the server's `interrupted` does that.
    func noteSpeechOnset() -> Bool {
        state.withLock { state in
            guard state.clientBargeIn else { return false }
            state.bargeIn = true
            return true
        }
    }

    /// Pass nil once the session is gone. Nothing from any other session gets past this after it returns.
    func setCurrentSession(_ session: Int?, mode: LiveMode = .arrest) {
        state.withLock { state in
            state.session = session
            state.clientBargeIn = mode == .arrest
        }
    }

    /// The lock stays held across `play`, so a swap can't land between the check and the audio, and
    /// the flush after a swap always comes after anything the old session got in.
    func admitModelAudio(session: Int, play: () -> Void) -> ModelAudioAdmission {
        state.withLock { state in
            guard state.session == session else { return .stale }
            guard state.policy?.modelSpeechOpen ?? false, !state.bargeIn else { return .closed }
            play()
            return .played
        }
    }

    /// False, and `apply` not run, when the session has been replaced.
    func endModelTurn(session: Int, apply: () -> Void) -> Bool {
        state.withLock { state in
            guard state.session == session else { return false }
            state.bargeIn = false
            apply()
            return true
        }
    }

    /// Pass nil once the session is gone. Everything sent after that is dropped.
    func setCommands(_ commands: AsyncStream<LiveCommand>.Continuation?) {
        state.withLock { $0.commands = commands }
    }

    func send(_ command: LiveCommand) {
        state.withLock { $0.commands }?.yield(command)
    }

    func sendMicAudio(_ pcm: Data) {
        guard micOpen else { return }
        send(.audio(pcm))
    }

    func sendAudioEnd() {
        guard micOpen else { return }
        send(.audioEnd)
    }

    func sendFrame(_ jpeg: Data) {
        guard framesOpen else { return }
        send(.frame(jpeg))
    }
}
