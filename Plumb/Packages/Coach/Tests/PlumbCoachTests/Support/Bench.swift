import Foundation
import PlumbContracts
@testable import PlumbCoach

/// What the made-up rescuer is doing and what the made-up analyzer reports about it, for a stretch of ticks.
struct Scene {
    /// Real compressions per minute. 0 means the hands are still.
    var cadence: Double = 110
    /// The rate the analyzer reports.
    var ratePerMin: Double? = 110
    /// The typical depth the analyzer reports. Given even when the lock says not to trust it.
    var depthMM: Double? = 55
    var lock: LockState = .locked
    var isPaused = false

    /// Compressing at a steady rate and depth. The defaults are comfortably inside the adult targets.
    static func compressing(depthMM: Double? = 55, ratePerMin: Double = 110,
                            lock: LockState = .locked) -> Scene {
        Scene(cadence: ratePerMin, ratePerMin: ratePerMin, depthMM: depthMM, lock: lock)
    }

    /// Hands still, and the analyzer has called it a pause. The rolling numbers stay as they were.
    static func paused(lock: LockState = .locked, depthMM: Double? = 55, ratePerMin: Double? = 110) -> Scene {
        Scene(cadence: 0, ratePerMin: ratePerMin, depthMM: depthMM, lock: lock, isPaused: true)
    }

    /// The same readings with no new compressions arriving, but not yet called a pause.
    var withHandsStill: Scene {
        var scene = self
        scene.cadence = 0
        return scene
    }
}

/// Drives a CuePolicy the way the app would: one hand-built Metrics per tick, a few times a second.
struct Bench {
    /// Seconds between looks. A power of two, so every threshold in the tests lands exactly on a tick.
    static let tick: TimeInterval = 0.125
    /// How long the made-up analyzer waits before calling stillness a pause.
    static let pauseNoticedAfterS: TimeInterval = 1.5

    /// One look and what the policy decided on it.
    struct Frame: Equatable {
        let t: TimeInterval
        let count: Int
        let speak: Cue?
        let show: Cue?
    }

    var policy: CuePolicy
    private(set) var frames: [Frame] = []
    private(set) var count = 0
    private var ticks = 0
    private var strokeProgress = 0.0
    private var pauseSeconds = 0.0

    init(policy: CuePolicy = CuePolicy()) {
        self.policy = policy
    }

    var now: TimeInterval { Double(ticks) * Self.tick }

    /// Advances one tick in the given scene and records the decision.
    @discardableResult
    mutating func step(_ scene: Scene, events: [SignalEvent] = []) -> Frame {
        ticks += 1
        strokeProgress += scene.cadence / 60 * Self.tick
        while strokeProgress >= 1 {
            strokeProgress -= 1
            count += 1
        }
        if scene.isPaused {
            pauseSeconds = pauseSeconds == 0 ? Self.pauseNoticedAfterS : pauseSeconds + Self.tick
        } else {
            pauseSeconds = 0
        }
        let metrics = Metrics(t: now, lock: scene.lock, count: count, ratePerMin: scene.ratePerMin,
                              depthMM: scene.depthMM, isPaused: scene.isPaused, pauseSeconds: pauseSeconds)
        let decision = policy.update(metrics: metrics, events: events, now: now)
        let frame = Frame(t: now, count: count, speak: decision.speak, show: decision.show)
        frames.append(frame)
        return frame
    }

    /// Runs one scene for a length of time. Returns only the frames from this stretch.
    @discardableResult
    mutating func run(seconds: TimeInterval, _ scene: Scene) -> [Frame] {
        run(seconds: seconds) { _ in scene }
    }

    /// Runs one scene until a look satisfies the condition and returns that look.
    /// Gives up after `limit` seconds and returns nil, so a broken rule fails the test instead of hanging it.
    mutating func run(_ scene: Scene, until condition: (Frame) -> Bool, limit: TimeInterval = 120) -> Frame? {
        for _ in 0..<Int((limit / Self.tick).rounded()) {
            let frame = step(scene)
            if condition(frame) { return frame }
        }
        return nil
    }

    /// Runs for a length of time with the scene chosen per tick, for inputs that change from look to look.
    @discardableResult
    mutating func run(seconds: TimeInterval, scene: (Int) -> Scene) -> [Frame] {
        let steps = Int((seconds / Self.tick).rounded())
        return (0..<steps).map { step(scene($0)) }
    }
}

/// One cue said at one moment.
struct Utterance: Equatable {
    let t: TimeInterval
    let cue: Cue

    init(_ t: TimeInterval, _ cue: Cue) {
        self.t = t
        self.cue = cue
    }
}

extension Sequence where Element == Bench.Frame {
    /// Everything that was said, in order.
    var utterances: [Utterance] {
        compactMap { frame in frame.speak.map { Utterance(frame.t, $0) } }
    }

    /// Only the spoken depth and rate corrections, in order.
    var spokenCorrectives: [Utterance] {
        utterances.filter { [.pushHarder, .faster, .slower].contains($0.cue) }
    }

    /// What the command slot showed over time, with consecutive repeats squeezed into one entry.
    var showChanges: [Cue?] {
        var changes: [Cue?] = []
        for frame in self where changes.isEmpty || changes[changes.count - 1] != frame.show {
            changes.append(frame.show)
        }
        return changes
    }

    /// True when nothing at all was said or shown.
    var isSilentAndBlank: Bool {
        allSatisfy { $0.speak == nil && $0.show == nil }
    }
}
