import AVFoundation

/// Listens for the things that silence an engine from outside: a phone call ending, headphones
/// coming or going, the hardware changing format, the system's audio services restarting.
/// Each is reported the same way, as "start again".
final class OutageWatcher {
    private var tokens: [any NSObjectProtocol] = []

    /// Watches `engine`. `startAgain` is always called later on the main queue, never from inside
    /// the notice itself, which can arrive on any thread and even during a call into the audio system.
    init(engine: AVAudioEngine, startAgain: @escaping @Sendable () -> Void) {
        watch(.AVAudioEngineConfigurationChange, from: engine, startAgain) { _ in true }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        watch(AVAudioSession.interruptionNotification, from: session, startAgain) { Self.interruptionEnded($0) }
        watch(AVAudioSession.routeChangeNotification, from: session, startAgain) { Self.deviceCameOrWent($0) }
        watch(AVAudioSession.mediaServicesWereResetNotification, from: session, startAgain) { _ in true }
        #endif
    }

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }

    private func watch(_ name: Notification.Name, from object: AnyObject, _ startAgain: @escaping @Sendable () -> Void,
                       when matters: @escaping @Sendable (Notification) -> Bool) {
        let token = NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { notice in
            if matters(notice) { DispatchQueue.main.async(execute: startAgain) }
        }
        tokens.append(token)
    }

    #if os(iOS)
    /// True for the end of an interruption. Its beginning needs nothing: the system has already stopped the engine.
    private static func interruptionEnded(_ notice: Notification) -> Bool {
        let raw = notice.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        return raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended
    }

    /// True when an output was plugged in or taken away. Other route changes, such as the one
    /// this package causes by setting the session category, must not restart the beat.
    private static func deviceCameOrWent(_ notice: Notification) -> Bool {
        let raw = notice.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        return reason == .newDeviceAvailable || reason == .oldDeviceUnavailable
    }
    #endif
}
