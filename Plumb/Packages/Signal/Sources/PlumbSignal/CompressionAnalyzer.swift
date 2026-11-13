import Foundation
import PlumbContracts

/// Turns a stream of hand-height samples into compressions, rolling metrics and a live stroke position.
///
/// Feed every sample to `ingest` and call `tick` a few times a second, then read `metrics` and `live`.
/// The only clock is the time stamps handed in, so the same input always gives the same output.
public struct CompressionAnalyzer: Sendable {
    /// Rolling summary of the session so far, as of the latest `ingest` or `tick`.
    public private(set) var metrics = Metrics.empty
    /// Where the hands are inside the stroke happening now, as of the latest accepted sample.
    public private(set) var live = LiveStroke()

    let config: Config
    let targets: Targets

    private var gate: SpikeGate
    private var smoother: HeightSmoother
    private var finder: StrokeFinder
    private var trust: LockTracker
    private var pauses: PauseLedger
    private var recent: RecentStrokes

    private var count = 0
    private var firstBottomT: TimeInterval?
    private var lastBottomT: TimeInterval?
    /// True when the next compression does not follow straight on from the last, so it has no interval.
    private var rhythmBroken = false

    /// Latest moment heard of, from a sample or a tick.
    private var clock = -TimeInterval.infinity
    private var lastSampleT: TimeInterval?
    /// Seconds of `clock` during which a signal was present. Pauses are timed on this, not on `clock`.
    private var seenS = 0.0

    /// Makes an analyzer. `targets` scale what counts as a believable stroke depth.
    public init(config: Config = .init(), targets: Targets = .adult) {
        self.config = config
        self.targets = targets
        gate = SpikeGate(jumpMM: config.spikeJumpMM, maxSpeedMMPerS: config.maxHandSpeedMMPerS)
        smoother = HeightSmoother(timeConstantS: config.smoothingTimeS)
        finder = StrokeFinder(config: config)
        trust = LockTracker(config: config)
        pauses = PauseLedger(pauseAfterS: config.pauseAfterS)
        recent = RecentStrokes(rateWindow: config.rateWindow, depthWindow: config.depthWindow)
    }

    /// Takes one sample and returns what it revealed, in order.
    /// A sample whose time is not after the previous one, or that is not a number, is ignored.
    public mutating func ingest(_ sample: HeightSample) -> [SignalEvent] {
        guard sample.t.isFinite, sample.heightMM.isFinite else { return [] }
        if let lastSampleT, sample.t <= lastSampleT { return [] }

        var events: [SignalEvent] = []
        advanceClock(to: sample.t, events: &events)
        lastSampleT = sample.t
        if let lock = trust.observe(quality: sample.quality, at: sample.t) {
            events.append(.lockChanged(lock, at: sample.t))
        }

        let (first, second) = gate.admit(t: sample.t, heightMM: sample.heightMM)
        if let first { follow(first, events: &events) }
        if let second { follow(second, events: &events) }
        live.lock = trust.state
        refreshMetrics()
        return events
    }

    /// Lets time pass without a sample, so that pauses and loss of signal are noticed.
    public mutating func tick(now: TimeInterval) -> [SignalEvent] {
        guard now.isFinite else { return [] }
        var events: [SignalEvent] = []
        advanceClock(to: now, events: &events)
        refreshMetrics()
        return events
    }

    /// Returns the analyzer to the state it was made in, keeping its configuration and targets.
    public mutating func reset() {
        self = CompressionAnalyzer(config: config, targets: targets)
    }
}

// MARK: - Time, pauses and loss of signal

private extension CompressionAnalyzer {
    /// Moves the clock forward, noticing on the way a pause that has become due or a signal that has gone.
    mutating func advanceClock(to now: TimeInterval, events: inout [SignalEvent]) {
        guard now > clock else { return }
        defer { clock = now }
        guard trust.state != .lost, let lastSampleT else { return }

        // A short silence is taken as "nothing changed". Past this point the analyzer is blind.
        let blindFrom = lastSampleT + config.lostAfterS
        seenS += max(0, min(now, blindFrom) - clock)
        if pauses.beginPauseIfDue(now: seenS), let lastBottomT {
            recent.clear()
            events.append(.pauseStarted(at: lastBottomT))
        }
        if now > blindFrom {
            loseSignal(at: blindFrom, events: &events)
        }
    }

    /// Marks the signal as lost and drops everything that depended on watching it without a break.
    mutating func loseSignal(at t: TimeInterval, events: inout [SignalEvent]) {
        guard trust.declareLost(at: t) else { return }
        events.append(.lockChanged(.lost, at: t))
        gate = SpikeGate(jumpMM: config.spikeJumpMM, maxSpeedMMPerS: config.maxHandSpeedMMPerS)
        smoother = HeightSmoother(timeConstantS: config.smoothingTimeS)
        finder = StrokeFinder(config: config)
        recent.clear()
        rhythmBroken = true
        live = LiveStroke(t: t, currentDepthMM: 0, lock: .lost)
    }
}

// MARK: - Strokes

private extension CompressionAnalyzer {
    /// Runs one cleaned reading through smoothing and stroke finding.
    mutating func follow(_ reading: CleanReading, events: inout [SignalEvent]) {
        let smoothMM = smoother.smooth(reading)
        if let candidate = finder.process(reading, smoothMM: smoothMM) {
            consider(candidate, events: &events)
        }
        live = LiveStroke(t: reading.t, currentDepthMM: finder.liveDepthMM, lock: trust.state)
    }

    /// Counts a candidate as a compression if it is a believable one, and reports it.
    mutating func consider(_ candidate: StrokeCandidate, events: inout [SignalEvent]) {
        guard isBelievable(candidate) else { return }

        let bottomSeenAt = seenS - (clock - candidate.tBottom)
        var intervalS: Double?
        if let pauseLength = pauses.recordStroke(at: bottomSeenAt) {
            events.append(.pauseEnded(at: candidate.tBottom, duration: pauseLength))
        } else if !rhythmBroken, let lastBottomT {
            intervalS = candidate.tBottom - lastBottomT
        }
        rhythmBroken = false

        count += 1
        firstBottomT = firstBottomT ?? candidate.tBottom
        lastBottomT = candidate.tBottom
        let lock = trust.state(at: candidate.tBottom)
        recent.add(depthMM: candidate.depthMM, trusted: lock == .locked, intervalS: intervalS)
        events.append(.compression(Compression(index: count, tTop: candidate.tTop, tBottom: candidate.tBottom,
                                               depthMM: candidate.depthMM, intervalS: intervalS, lock: lock)))
    }

    func isBelievable(_ candidate: StrokeCandidate) -> Bool {
        let shallowest = config.minDepthFraction * targets.depthMinMM
        let deepest = config.maxDepthFactor * targets.depthMaxMM
        guard (shallowest...deepest).contains(candidate.depthMM),
              candidate.heldDepthMM >= config.minHeldDepthShare * shallowest,
              (config.minDescentS...config.maxDescentS).contains(candidate.descentS)
        else { return false }
        if let lastBottomT, candidate.tBottom - lastBottomT < config.refractoryS { return false }
        return true
    }

    mutating func refreshMetrics() {
        metrics = Metrics(t: clock, lock: trust.state, count: count, ratePerMin: recent.ratePerMin,
                          depthMM: recent.depthMM, depthSpreadMM: recent.depthSpreadMM,
                          secondsSinceLastCompression: lastBottomT.map { max(0, clock - $0) },
                          isPaused: pauses.isPaused, pauseSeconds: pauses.currentPauseS(now: seenS),
                          handsOnFraction: pauses.handsOnFraction(now: seenS),
                          firstCompressionAt: firstBottomT)
    }
}
