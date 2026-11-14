import Foundation

/// A system problem someone needs to know about. One per line on screen, never cut to fit, because a
/// warning cut off to fit a row is no warning.
struct StatusAlert: Identifiable, Equatable {
    enum Weight: Equatable {
        /// Something to do, or a voice that can't be relied on.
        case act
        /// Paused on purpose. Nothing to do.
        case info
    }

    var text: String
    var symbol: String
    var weight: Weight
    var id: String { text }
}

extension AppCoordinator {
    /// In a fixed order, with the same words the stage script reads. All caution, none red, since red
    /// means a life threat and these are the phone's problems.
    var statusAlerts: [StatusAlert] {
        var alerts: [StatusAlert] = []
        if state.callActive {
            alerts.append(StatusAlert(text: "Call active, tap Speaker", symbol: "phone.connection.fill", weight: .act))
        }
        if aiPausedForCall {
            alerts.append(StatusAlert(text: "AI paused during call", symbol: "pause.circle.fill", weight: .info))
        }
        if aedTalking {
            alerts.append(StatusAlert(text: "AED talking, phone paused", symbol: "speaker.badge.exclamationmark.fill", weight: .info))
        }
        if micClosedForDispatcher {
            alerts.append(StatusAlert(text: "Dispatcher heard, mic closed", symbol: "mic.badge.xmark", weight: .info))
        }
        if aiCannotHear {
            alerts.append(StatusAlert(text: "Mic problem, AI can't hear", symbol: "mic.slash.fill", weight: .act))
        }
        // No row for the AI going quiet: it fired on any noise and on an AI that was only watching, so
        // it was mostly noise itself. The buttons always work, and the AI read shows when the AI fails.
        switch audioHealth {
        case .outputLost:
            alerts.append(StatusAlert(text: "No sound, follow the screen", symbol: "speaker.slash.fill", weight: .act))
        case .voiceFailed:
            alerts.append(StatusAlert(text: "No voice, read the screen", symbol: "speaker.slash.fill", weight: .act))
        case .starting, .ok:
            break
        }
        return alerts
    }
}
