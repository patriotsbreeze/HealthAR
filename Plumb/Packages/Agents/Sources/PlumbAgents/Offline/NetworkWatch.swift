import Foundation
import Network

/// Whether the phone has a network path right now, so the app can choose between the live voice and
/// the offline path for each press of "Hold to ask".
///
/// Online means the system has a usable path. It does not promise the voice service will answer, so
/// the app still falls back to the offline path while the live voice is not connected.
public final class NetworkWatch: @unchecked Sendable {
    /// Each change of `isOnline`, as it happens. Repeats of the same state are not sent.
    public let changes: AsyncStream<Bool>

    private let monitor: NWPathMonitor?
    private let feed: AsyncStream<Bool>.Continuation
    private let lock = NSLock()
    // Guarded by `lock`.
    private var online = false

    /// Starts watching at once. Until the system reports the first path the phone counts as offline,
    /// which picks the path that needs nothing.
    public convenience init() {
        self.init(monitor: NWPathMonitor())
    }

    /// - Parameter monitor: nil watches nothing, for tests that report paths by hand.
    init(monitor: NWPathMonitor?) {
        self.monitor = monitor
        let (changes, feed) = AsyncStream<Bool>.makeStream()
        self.changes = changes
        self.feed = feed
        monitor?.pathUpdateHandler = { [weak self] path in
            self?.record(path.status)
        }
        monitor?.start(queue: DispatchQueue(label: "plumb.network-watch"))
    }

    deinit {
        monitor?.cancel()
        feed.finish()
    }

    /// True when the system reports a usable network path.
    public var isOnline: Bool {
        lock.withLock { online }
    }

    /// Takes in one path status from the system.
    func record(_ status: NWPath.Status) {
        let now = status == .satisfied
        let changed = lock.withLock { () -> Bool in
            defer { online = now }
            return online != now
        }
        if changed { feed.yield(now) }
    }
}

/// Which voice answers a press of "Hold to ask".
public enum AskRoute: String, Sendable, Equatable {
    /// The live voice service, which needs the network and a key.
    case live
    /// Speech to text, intent and a fixed answer, all on the phone.
    case onDevice

    /// The live voice only when there is a network path, a key and an open connection to the voice
    /// service; otherwise the phone answers. A connection that is still opening, or that has dropped,
    /// would drop the question unheard, so it goes to the phone instead.
    public static func choose(isOnline: Bool, hasKey: Bool, voiceConnected: Bool) -> AskRoute {
        isOnline && hasKey && voiceConnected ? .live : .onDevice
    }
}
