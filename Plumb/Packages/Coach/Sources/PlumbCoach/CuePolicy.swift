import Foundation
import PlumbContracts

/// The fixed rule set that decides what the rescuer is told. Feed it every Metrics reading;
/// it answers with at most one cue for the screen and, rarely, one to say out loud.
public struct CuePolicy: Sendable {
    /// The tunable numbers these rules run on.
    public let config: Config
    /// The depth and rate the rescuer is being coached towards.
    public let targets: Targets

    /// Readable inside the module so tests can check that a reset really empties it.
    private(set) var memory = Memory()

    /// Makes a rule set with nothing remembered, ready for the start of a session.
    public init(config: Config = .init(), targets: Targets = .adult) {
        self.config = config
        self.targets = targets
    }

    /// Takes one look at the measurements and says what to display and what, if anything, to say.
    /// `now` is the only clock the rules use; call this a few times a second with a time that never goes backwards.
    public mutating func update(metrics: Metrics, events: [SignalEvent], now: TimeInterval) -> Decision {
        let runBroke = memory.tally.absorb(metrics: metrics, events: events)
        memory.signal.note(lock: metrics.lock, events: events, now: now)

        // Before the first compression there is nothing to correct, however long the wait.
        guard memory.tally.hasStarted else { return Decision() }

        if runBroke {
            // What was measured before a pause says nothing about the compressions after it.
            memory.faults.clear()
            memory.praise.breakStreak()
        }
        if !metrics.isPaused { memory.speech.pauseEnded() }

        let sight = Sight(metrics: metrics, compressionsSincePause: memory.tally.sincePause,
                          minCompressionsForRate: config.minCompressionsForRate)
        memory.faults.observe(sight, targets: targets, config: config, now: now)

        var decision = Decision()
        if let corrective = corrective(for: metrics, sight: sight, now: now) {
            decision.show = corrective
            if maySay(corrective, metrics: metrics, now: now) { decision.speak = corrective }
            memory.praise.interrupt()
        } else {
            // With the hands still or the signal gone, nothing on screen may claim the work is good.
            if metrics.isPaused || metrics.lock == .lost { memory.praise.hide() }
            if memory.praise.earn(sight.quality(against: targets), compressions: memory.tally.total,
                                  now: now, config: config) {
                decision.speak = .good
            }
            if memory.praise.isShowing(at: now) { decision.show = .good }
        }

        if let said = decision.speak {
            memory.speech.record(said, compressions: memory.tally.total, now: now)
        }
        return decision
    }

    /// Forgets everything, as at the start of a new session. Config and targets are kept.
    public mutating func reset() {
        memory = Memory()
    }

    /// The one correction worth showing right now, most urgent first: a pause, then depth, then rate.
    private func corrective(for metrics: Metrics, sight: Sight, now: TimeInterval) -> Cue? {
        if metrics.isPaused {
            // A pause seen through a lost or barely recovered signal may only be the signal's doing.
            return memory.signal.isSteady(at: now, settleS: config.signalSettleS) ? .pushNow : nil
        }
        return memory.faults.confirmed(in: sight)
    }

    /// Whether the correction on screen may also be said on this look.
    private func maySay(_ corrective: Cue, metrics: Metrics, now: TimeInterval) -> Bool {
        if corrective == .pushNow {
            return memory.speech.allowsPushNow(pauseSeconds: metrics.pauseSeconds, now: now, config: config)
        }
        return memory.speech.allowsCorrective(corrective, compressions: memory.tally.total,
                                              now: now, config: config)
    }
}

extension CuePolicy {
    /// Everything the rules remember between looks.
    struct Memory: Equatable, Sendable {
        var tally = RunTally()
        var signal = SignalWatch()
        var faults = FaultBoard()
        var speech = SpeechThrottle()
        var praise = PraiseLedger()
    }
}
