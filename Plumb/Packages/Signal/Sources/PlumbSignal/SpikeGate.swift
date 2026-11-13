import Foundation

/// A height reading that passed the spike gate. Heights stay continuous across shifts of the reference.
struct CleanReading: Equatable, Sendable {
    var t: TimeInterval
    var heightMM: Double
}

/// Removes one-sample spikes and cancels sudden shifts of the height reference.
///
/// A sample that jumps far from the one before is held for one sample. If the next sample goes back,
/// the held one was a spike and is dropped. If the next sample stays with it, the jump was real:
/// either fast motion, which passes through, or a shift no hand could make, which is subtracted
/// from everything that follows so a stroke in progress is not broken.
struct SpikeGate: Sendable {
    private let jumpMM: Double
    private let maxSpeedMMPerS: Double
    /// Last sample let through, as it arrived (before any shift was subtracted).
    private var previous: CleanReading?
    private var held: CleanReading?
    private var shiftMM = 0.0

    init(jumpMM: Double, maxSpeedMMPerS: Double) {
        self.jumpMM = jumpMM
        self.maxSpeedMMPerS = maxSpeedMMPerS
    }

    /// Takes one raw sample and returns the readings it releases, oldest first: none, one or two.
    mutating func admit(t: TimeInterval, heightMM: Double) -> (CleanReading?, CleanReading?) {
        let incoming = CleanReading(t: t, heightMM: heightMM)
        let released = settleHeld(given: incoming)

        if let previous, abs(heightMM - previous.heightMM) > jumpMM {
            held = incoming
            return (released, nil)
        }
        previous = incoming
        let passed = CleanReading(t: t, heightMM: heightMM - shiftMM)
        return released == nil ? (passed, nil) : (released, passed)
    }

    /// Decides the fate of the held sample now that the next one is known. Returns it if it was real.
    private mutating func settleHeld(given next: CleanReading) -> CleanReading? {
        guard let suspect = held, let previous else { return nil }
        held = nil
        let jump = suspect.heightMM - previous.heightMM
        let nextJump = next.heightMM - previous.heightMM
        let wentBack = abs(nextJump) < abs(next.heightMM - suspect.heightMM)
        if wentBack { return nil }

        // A shift of the reference is a jump too fast for a hand that the following sample repeats in full.
        // Demanding both keeps two noisy samples in a row from being mistaken for one. The whole jump is
        // taken as shift, as if the hands stood still for that one sample.
        let tooFastForAHand = abs(jump) > maxSpeedMMPerS * (suspect.t - previous.t)
        let repeated = nextJump * jump > 0 && abs(nextJump) > jumpMM
        if tooFastForAHand && repeated {
            shiftMM += jump
        }
        self.previous = suspect
        return CleanReading(t: suspect.t, heightMM: suspect.heightMM - shiftMM)
    }
}
