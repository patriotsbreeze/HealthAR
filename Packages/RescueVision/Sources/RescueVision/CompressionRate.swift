import Foundation
import simd

/// EXPERIMENTAL, plan S1. Compression rate from the rescuer's arm motion, for a manikin with the
/// phone helper-held or propped at about 1 m. Rate only: depth from a phone camera isn't
/// trustworthy, so nothing here scores it. Silent whenever it isn't sure, and never reassuring.

/// One frame's reading of the rescuer: how far along world down their upper body sits, and their
/// arm's length, both in aspect-corrected capture image units.
struct CompressionSample: Sendable, Equatable {
    var position: Double
    var scale: Double
    /// Both elbows straight enough, from the arms pose saw. Nil when no arm was seen whole.
    var armsLocked: Bool?
    /// Between the wrists, in capture image space.
    var wrists: SIMD2<Double> = .zero
}

enum CompressionSignal {
    /// Joints below this are too faint to time a push from.
    static let minConfidence = 0.3
    /// Shoulder to wrist has to point this close to world down, about 50 degrees. The patient's
    /// arms lie across gravity, so this is what tells the rescuer from the person on the floor.
    static let minArmsDown = 0.65
    /// Shoulder, elbow and wrist this close to a straight line, in degrees, counts as locked. A
    /// bent elbow on a push is past 30 degrees, and pose jitters by about 10.
    static let lockedElbowDegrees = 155.0

    /// Nil without gravity, since then nothing says which way a push goes.
    static func sample(people: [DetectedPerson], gravity: SIMD2<Double>?, imageAspect: Double) -> CompressionSample? {
        guard let gravity, simd_length(gravity) > 1e-6 else { return nil }
        // Image units are normalized per axis, so x is stretched back by the aspect to keep angles true.
        let stretch = SIMD2(imageAspect, 1)
        let down = simd_normalize(gravity * stretch)

        var best: CompressionSample?
        for person in people {
            guard let shoulders = midpoint(person, .leftShoulder, .rightShoulder),
                  let wrists = midpoint(person, .leftWrist, .rightWrist) else { continue }
            let arm = (wrists - shoulders) * stretch
            let length = simd_length(arm)
            guard length > 1e-6, simd_dot(arm / length, down) >= minArmsDown else { continue }
            // Shoulders and wrists both move with a locked-arm push, so their mean halves the jitter.
            let center = (shoulders + wrists) / 2 * stretch
            let sample = CompressionSample(
                position: simd_dot(center, down),
                scale: length,
                armsLocked: armsLocked(person, stretch: stretch),
                wrists: wrists
            )
            // More than one rescuer-shaped person: the biggest is the one nearest the camera.
            if sample.scale > (best?.scale ?? 0) { best = sample }
        }
        return best
    }

    /// Every arm seen whole has to be straight. An arm half hidden behind the body says nothing.
    private static func armsLocked(_ person: DetectedPerson, stretch: SIMD2<Double>) -> Bool? {
        let arms: [(BodyJoint, BodyJoint, BodyJoint)] = [
            (.leftShoulder, .leftElbow, .leftWrist),
            (.rightShoulder, .rightElbow, .rightWrist),
        ]
        var seen = false
        for (s, e, w) in arms {
            guard let shoulder = seenJoint(person, s), let elbow = seenJoint(person, e), let wrist = seenJoint(person, w) else { continue }
            let upper = (shoulder - elbow) * stretch, lower = (wrist - elbow) * stretch
            guard simd_length(upper) > 1e-6, simd_length(lower) > 1e-6 else { continue }
            let cosine = simd_dot(simd_normalize(upper), simd_normalize(lower))
            let degrees = acos(min(1, max(-1, cosine))) * 180 / .pi
            seen = true
            if degrees < lockedElbowDegrees { return false }
        }
        return seen ? true : nil
    }

    private static func seenJoint(_ person: DetectedPerson, _ name: BodyJoint) -> SIMD2<Double>? {
        person.joint(name).flatMap { $0.confidence >= minConfidence ? $0.position : nil }
    }

    /// Both joints when both are seen, else the one that is.
    private static func midpoint(_ person: DetectedPerson, _ a: BodyJoint, _ b: BodyJoint) -> SIMD2<Double>? {
        let seen = [a, b].compactMap(person.joint).filter { $0.confidence >= minConfidence }.map(\.position)
        guard !seen.isEmpty else { return nil }
        return seen.reduce(.zero, +) / Double(seen.count)
    }
}

struct CompressionRate: Sendable, Equatable {
    var perMinute: Double
    /// The autocorrelation at the chosen period, 0 to 1.
    var confidence: Double

    enum Verdict: Sendable, Equatable { case tooSlow, inRange, tooFast }

    /// AHA 2025: 100 to 120 a minute.
    static let target: ClosedRange<Double> = 100...120

    var verdict: Verdict {
        if perMinute < Self.target.lowerBound { return .tooSlow }
        if perMinute > Self.target.upperBound { return .tooFast }
        return .inRange
    }
}

/// The period of the last few seconds of samples, by autocorrelation. A peak picker would miss
/// pushes at a 15 FPS pose cap; correlating whole cycles uses every frame.
struct CompressionRateEstimator: Sendable {
    static let window: TimeInterval = 5
    /// Less history than this says nothing about a steady rate.
    static let minSpan: TimeInterval = 3
    /// A longer gap than this, from dropped tracking or a pause, starts over.
    static let maxGap: TimeInterval = 0.4
    /// The newest sample has to be this fresh, or the rescuer is out of view.
    static let maxStaleness: TimeInterval = 0.5
    /// Samples are resampled to this before correlating.
    static let resampleRate = 30.0
    /// The search band, wider than the target so too slow and too fast both read.
    static let searchBand: ClosedRange<Double> = 60...180
    static let minCorrelation = 0.6
    /// Standard deviation of the motion in arm lengths. A 5 cm push on a 60 cm arm is about 0.03.
    static let minAmplitude = 0.01
    /// A shorter period within this much of the best correlation wins, so a fast rate never
    /// reads as half itself.
    static let shorterPeriodTolerance = 0.9

    private var samples: [(time: TimeInterval, sample: CompressionSample)] = []

    mutating func reset() { samples.removeAll() }

    mutating func add(_ sample: CompressionSample, at time: TimeInterval) {
        if let last = samples.last {
            guard time > last.time else { return }
            if time - last.time > Self.maxGap { samples.removeAll() }
        }
        samples.append((time, sample))
        let cutoff = time - Self.window
        if let keep = samples.firstIndex(where: { $0.time >= cutoff }), keep > 0 {
            samples.removeFirst(keep)
        }
    }

    func estimate(at now: TimeInterval) -> CompressionRate? {
        guard let first = samples.first, let last = samples.last,
              now - last.time <= Self.maxStaleness,
              last.time - first.time >= Self.minSpan else { return nil }

        let signal = detrended(resampled(from: first.time, to: last.time))
        let scale = samples.map(\.sample.scale).reduce(0, +) / Double(samples.count)
        let variance = signal.map { $0 * $0 }.reduce(0, +) / Double(signal.count)
        guard scale > 0, variance.squareRoot() / scale >= Self.minAmplitude else { return nil }

        let fs = Self.resampleRate
        let minLag = Int((fs * 60 / Self.searchBand.upperBound).rounded(.down))
        let maxLag = Int((fs * 60 / Self.searchBand.lowerBound).rounded(.up))
        // Two whole cycles at the slowest rate, so every lag is correlated over enough overlap.
        guard signal.count > maxLag * 2 else { return nil }

        let r = (0...maxLag + 1).map { autocorrelation(signal, lag: $0) }
        let peaks = (max(1, minLag)...maxLag).filter { r[$0] > r[$0 - 1] && r[$0] >= r[$0 + 1] }
        guard let best = peaks.map({ r[$0] }).max(), best >= Self.minCorrelation,
              let lag = peaks.first(where: { r[$0] >= best * Self.shorterPeriodTolerance }) else { return nil }

        // A parabola through the peak and its neighbors places it between samples.
        let (a, b, c) = (r[lag - 1], r[lag], r[lag + 1])
        let curvature = a - 2 * b + c
        let offset = curvature < 0 ? 0.5 * (a - c) / curvature : 0
        let period = (Double(lag) + offset) / fs
        let perMinute = 60 / period
        guard Self.searchBand.contains(perMinute) else { return nil }
        return CompressionRate(perMinute: perMinute, confidence: min(1, r[lag]))
    }

    /// How far the rescuer's deepest point trails the beat, in beats from -0.5 to 0.5: positive is
    /// behind the ghost, negative ahead. Nil whenever `estimate` is, since a phase of no rhythm means nothing.
    func beatOffset(at now: TimeInterval, beatStart: TimeInterval, interval: TimeInterval) -> Double? {
        guard interval > 0, estimate(at: now) != nil, let first = samples.first, let last = samples.last else { return nil }
        let signal = detrended(resampled(from: first.time, to: last.time))
        var c = 0.0, s = 0.0
        for (i, x) in signal.enumerated() {
            let t = first.time + Double(i) / Self.resampleRate
            let angle = 2 * .pi * (t - beatStart) / interval
            c += x * cos(angle)
            s += x * sin(angle)
        }
        guard c != 0 || s != 0 else { return nil }
        // The ghost is deepest on the beat. A rescuer deepest a little after it puts the peak at a positive angle.
        return atan2(s, c) / (2 * .pi)
    }

    /// Evenly spaced, by straight lines between the frames pose actually saw.
    private func resampled(from start: TimeInterval, to end: TimeInterval) -> [Double] {
        let count = Int(((end - start) * Self.resampleRate).rounded(.down)) + 1
        var values: [Double] = []
        values.reserveCapacity(count)
        var index = 0
        for step in 0..<count {
            let t = start + Double(step) / Self.resampleRate
            while index + 1 < samples.count - 1, samples[index + 1].time < t { index += 1 }
            let a = samples[index], b = samples[min(index + 1, samples.count - 1)]
            let span = b.time - a.time
            let f = span > 0 ? min(1, max(0, (t - a.time) / span)) : 0
            values.append(a.sample.position + f * (b.sample.position - a.sample.position))
        }
        return values
    }

    /// Less its straight-line fit, so a helper's slow drift isn't read as motion.
    private func detrended(_ values: [Double]) -> [Double] {
        let n = Double(values.count)
        let meanX = (n - 1) / 2
        let meanY = values.reduce(0, +) / n
        var covariance = 0.0, varianceX = 0.0
        for (i, y) in values.enumerated() {
            let dx = Double(i) - meanX
            covariance += dx * (y - meanY)
            varianceX += dx * dx
        }
        let slope = varianceX > 0 ? covariance / varianceX : 0
        return values.enumerated().map { i, y in y - meanY - slope * (Double(i) - meanX) }
    }

    /// Normalized over the overlap, so long lags aren't penalized for having fewer pairs.
    private func autocorrelation(_ x: [Double], lag: Int) -> Double {
        guard lag < x.count else { return 0 }
        var sum = 0.0, head = 0.0, tail = 0.0
        for i in 0..<(x.count - lag) {
            sum += x[i] * x[i + lag]
            head += x[i] * x[i]
            tail += x[i + lag] * x[i + lag]
        }
        let norm = (head * tail).squareRoot()
        return norm > 0 ? sum / norm : 0
    }
}
