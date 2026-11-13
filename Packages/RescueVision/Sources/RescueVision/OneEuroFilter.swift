import Foundation
import simd

/// The 1-Euro filter (Casiez et al., CHI 2012): smooths hard when a point is still and lets it
/// follow when it moves fast, so marks stop jittering without trailing behind a real move.
/// This is the one place pose is smoothed. Marks placed in the world are already steady and
/// are not smoothed again.
struct OneEuroFilter: Sendable, Equatable {
    /// Hz. Lower is smoother when still.
    var minCutoff: Double
    /// Per image height per second. The paper's 0.01 is per pixel, and an image is about 1440 px tall.
    var beta: Double
    var derivativeCutoff: Double
    /// A longer gap than this starts over, since the old value says nothing about now.
    static let maxGap: TimeInterval = 0.5

    private var value: SIMD2<Double>?
    private var derivative = SIMD2<Double>.zero
    private var time: TimeInterval = 0

    init(minCutoff: Double = 1.2, beta: Double = 14, derivativeCutoff: Double = 1) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    /// The first sample, and any after a gap or out of order, passes through unchanged.
    mutating func filter(_ sample: SIMD2<Double>, at now: TimeInterval) -> SIMD2<Double> {
        guard let value, now > time, now - time <= Self.maxGap else {
            value = sample
            derivative = .zero
            time = now
            return sample
        }
        let dt = now - time
        derivative += Self.alpha(cutoff: derivativeCutoff, dt: dt) * ((sample - value) / dt - derivative)
        let cutoff = minCutoff + beta * simd_length(derivative)
        // Written as a step toward the sample, so a sample equal to the value returns it exactly.
        let next = value + Self.alpha(cutoff: cutoff, dt: dt) * (sample - value)
        self.value = next
        time = now
        return next
    }

    mutating func reset() {
        value = nil
        derivative = .zero
    }

    private static func alpha(cutoff: Double, dt: TimeInterval) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

/// One filter per joint, in isotropic image heights so x and y smooth alike.
struct JointSmoother: Sendable {
    /// A mean jump this big, in image heights, is a different person, and their joints shouldn't
    /// glide over from the last one's.
    static let newPersonJump = 0.15

    private var filters: [BodyJoint: OneEuroFilter] = [:]
    private var lastRaw: [BodyJoint: SIMD2<Double>] = [:]

    mutating func smooth(_ person: DetectedPerson, at now: TimeInterval, imageAspect: Double) -> DetectedPerson {
        guard imageAspect > 0 else { return person }
        let iso: (SIMD2<Double>) -> SIMD2<Double> = { [$0.x * imageAspect, $0.y] }
        let raw = person.allPositions.mapValues(iso)
        let shared = raw.keys.filter { lastRaw[$0] != nil }
        if !shared.isEmpty {
            let jump = shared.map { simd_distance(raw[$0]!, lastRaw[$0]!) }.reduce(0, +) / Double(shared.count)
            if jump > Self.newPersonJump { filters = [:] }
        }
        lastRaw = raw
        return person.mapPositions { name, position in
            let smoothed = filters[name, default: OneEuroFilter()].filter(iso(position), at: now)
            return [smoothed.x / imageAspect, smoothed.y]
        }
    }

    mutating func reset() {
        filters = [:]
        lastRaw = [:]
    }
}
