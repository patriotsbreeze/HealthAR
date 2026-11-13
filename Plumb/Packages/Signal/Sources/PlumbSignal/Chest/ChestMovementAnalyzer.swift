import Foundation
import PlumbContracts

/// Watches the height of a tapped chest patch and says whether it has moved, without touching anyone.
///
/// Feed every sample to `ingest` and call `tick` a few times a second for a reading. The samples are the
/// chest patch's height against a still reference, as Capture measures it once the chest is tapped.
/// Once the chest has stayed still for long enough the reading prompts "Start pushing", and from then on
/// it keeps prompting whatever the chest does: only `reset()`, asked for by a person, takes the prompt back.
/// The only clock is the time stamps handed in, so the same input always gives the same readings.
public struct ChestMovementAnalyzer: Sendable {
    /// How much the still reference appears to move, in millimetres, as Capture reports it. Nil when unknown.
    /// Movement must be at least `Config.noiseMultiple` times this, and never less than `Config.minSwingMM`.
    /// Set it whenever a new figure arrives; it applies from the next bin on.
    public var noiseFloorMM: Double?

    /// The numbers the check runs by.
    public let config: Config

    private var run: ChestRun?
    private var prompt = PromptLatch()
    /// Latest moment heard of, from a sample or a tick.
    private var clock = -TimeInterval.infinity
    private var lastSampleT: TimeInterval?

    /// Makes a check that has seen nothing yet.
    public init(config: Config = .init(), noiseFloorMM: Double? = nil) {
        self.config = config
        self.noiseFloorMM = noiseFloorMM
    }

    /// The rise or fall, in millimetres, that counts as movement with the current noise floor.
    public var thresholdMM: Double {
        let floor = noiseFloorMM.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        return max(config.minSwingMM, config.noiseMultiple * floor)
    }

    /// Takes one sample. A sample whose time is not after the previous one, or that is not a number, is ignored.
    /// A sample below `Config.minQuality` moves the clock but is not measured.
    public mutating func ingest(_ sample: HeightSample) {
        guard sample.t.isFinite, sample.heightMM.isFinite else { return }
        if let lastSampleT, sample.t <= lastSampleT { return }
        lastSampleT = sample.t
        advanceClock(to: sample.t)
        guard sample.quality >= config.minQuality else { return }

        let threshold = thresholdMM
        if run == nil {
            run = ChestRun(firstSampleAt: sample.t, config: config)
        }
        run?.add(t: sample.t, heightMM: sample.heightMM, thresholdMM: threshold)
        promptIfDue(seenUntil: clock)
    }

    /// Lets time pass, notices when samples have stopped, and returns the reading as of `now`.
    public mutating func tick(now: TimeInterval) -> ChestReading {
        if now.isFinite {
            advanceClock(to: now)
            promptIfDue(seenUntil: clock)
        }
        return reading
    }

    /// Starts watching afresh, as after a gap, keeping the prompt. For when the chest is tapped again.
    public mutating func restartWatching() {
        run = nil
    }

    /// Returns the check to the state it was made in, prompt included, keeping its configuration and noise floor.
    /// The one way to clear "Start pushing". Call it only when a person asks.
    public mutating func reset() {
        self = ChestMovementAnalyzer(config: config, noiseFloorMM: noiseFloorMM)
    }
}

private extension ChestMovementAnalyzer {
    /// Moves the clock forward and ends the stretch of watching once samples have stopped for too long.
    mutating func advanceClock(to now: TimeInterval) {
        guard now > clock else { return }
        clock = now
        guard let run else { return }
        // A short silence is taken as "nothing changed". Past this point the chest is not being seen.
        let blindFrom = run.lastSampleT + config.lostAfterS
        if now > blindFrom {
            promptIfDue(seenUntil: blindFrom)
            self.run = nil
        }
    }

    /// Turns the prompt on once the chest has been seen still for long enough.
    mutating func promptIfDue(seenUntil: TimeInterval) {
        guard let run, case .noMovementSeen = state(of: run, seenUntil: seenUntil) else { return }
        prompt.fire(at: run.quietFrom + config.noMovementAfterS)
    }

    func state(of run: ChestRun, seenUntil: TimeInterval) -> ChestReading.State {
        let quietS = seenUntil - run.quietFrom
        if quietS >= config.noMovementAfterS { return .noMovementSeen(forSeconds: quietS) }
        if seenUntil - run.startT < config.settleS { return .settling }
        if run.hasSwung, quietS < config.windowS { return .movementSeen }
        return .settling
    }

    var reading: ChestReading {
        let threshold = thresholdMM
        return ChestReading(t: clock.isFinite ? clock : 0,
                            state: run.map { state(of: $0, seenUntil: clock) } ?? .unmeasured,
                            startPushing: prompt.isOn,
                            promptedAt: prompt.firedAt,
                            thresholdMM: threshold,
                            swingMM: run?.swingMM,
                            trace: run?.trace(thresholdMM: threshold) ?? .blank(config))
    }
}
