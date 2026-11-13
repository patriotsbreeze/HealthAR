import Foundation
import PlumbContracts

/// A yes/no reading behind a meter that fills while the evidence says yes and drains while it says no.
/// It turns on only when full and off only when empty, so short contradictions change nothing.
struct EvidenceMeter: Sendable {
    private(set) var isOn = false
    /// 0 is empty, 1 is full.
    private var level = 0.0

    /// Counts `elapsed` seconds of evidence. `fillS` and `drainS` are how long a full swing takes each way.
    mutating func feed(_ yes: Bool, for elapsed: Double, fillS: Double, drainS: Double) {
        let swingS = yes ? fillS : drainS
        let change = swingS > 0 ? elapsed / swingS : 1
        level = min(1, max(0, level + (yes ? change : -change)))
        if level >= 1 {
            isOn = true
        } else if level <= 0 {
            isOn = false
        }
    }
}

/// Decides how far the measurement can be trusted, from the quality of each sample.
///
/// Trust rises after about a second of good quality and falls after a shorter spell of poor quality.
/// A brief dip, a brief flash of good quality, or quality hovering at a threshold does not make it flicker.
struct LockTracker: Sendable {
    private let config: CompressionAnalyzer.Config
    private(set) var state = LockState.lost
    private var earlierState = LockState.lost
    private var changedAt = -TimeInterval.infinity
    private var lockedMeter = EvidenceMeter()
    private var estimatingMeter = EvidenceMeter()
    private var lastSampleT: TimeInterval?

    init(config: CompressionAnalyzer.Config) {
        self.config = config
    }

    /// Takes one sample's quality. Returns the new state if it changed.
    mutating func observe(quality: Double, at t: TimeInterval) -> LockState? {
        let quality = quality.isNaN ? 0 : quality
        let elapsed = lastSampleT.map { t - $0 } ?? 0
        lastSampleT = t
        lockedMeter.feed(quality >= config.lockedQuality, for: elapsed,
                         fillS: config.trustGainS, drainS: config.trustLossS)
        estimatingMeter.feed(quality >= config.estimatingQuality, for: elapsed,
                             fillS: config.trustGainS, drainS: config.trustLossS)
        let next: LockState = lockedMeter.isOn ? .locked : (estimatingMeter.isOn ? .estimating : .rateOnly)
        return move(to: next, at: t) ? next : nil
    }

    /// Records that samples stopped arriving. Returns false if the signal was already lost.
    mutating func declareLost(at t: TimeInterval) -> Bool {
        lockedMeter = EvidenceMeter()
        estimatingMeter = EvidenceMeter()
        lastSampleT = nil
        return move(to: .lost, at: t)
    }

    /// The state as it was at `t`, which may be just before the latest change.
    func state(at t: TimeInterval) -> LockState {
        t < changedAt ? earlierState : state
    }

    private mutating func move(to next: LockState, at t: TimeInterval) -> Bool {
        guard next != state else { return false }
        earlierState = state
        state = next
        changedAt = t
        return true
    }
}
