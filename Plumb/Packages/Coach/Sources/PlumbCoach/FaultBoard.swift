import Foundation
import PlumbContracts

/// The three faults the rules can name, each remembered on its own.
///
/// There is deliberately no latch for too deep, for recoil or for leaning: none can be measured well enough.
struct FaultBoard: Equatable, Sendable {
    private var shallow = FaultLatch()
    private var slow = FaultLatch()
    private var fast = FaultLatch()

    /// Updates each fault from whatever this look allows to be judged. What cannot be judged is left as it was.
    mutating func observe(_ sight: Sight, targets: Targets, config: CuePolicy.Config, now: TimeInterval) {
        if let depthMM = sight.depthMM {
            shallow.observe(outsideBy: targets.depthMinMM - depthMM, deadBand: config.depthDeadBandMM,
                            persistS: config.persistS, now: now)
        }
        if let ratePerMin = sight.ratePerMin {
            slow.observe(outsideBy: targets.rateMinPerMin - ratePerMin, deadBand: config.rateDeadBandPerMin,
                         persistS: config.persistS, now: now)
            fast.observe(outsideBy: ratePerMin - targets.rateMaxPerMin, deadBand: config.rateDeadBandPerMin,
                         persistS: config.persistS, now: now)
        }
    }

    /// The most urgent believed fault, as the cue that corrects it. Depth outranks rate.
    ///
    /// A fault is only reported while its value can be judged on this look, so a depth fault
    /// is never shown on the strength of an untrusted depth.
    func confirmed(in sight: Sight) -> Cue? {
        if sight.depthMM != nil, shallow.isConfirmed { return .pushHarder }
        guard sight.ratePerMin != nil else { return nil }
        if slow.isConfirmed { return .faster }
        if fast.isConfirmed { return .slower }
        return nil
    }

    /// Forgets every fault, as after a pause.
    mutating func clear() {
        self = FaultBoard()
    }
}
