import Foundation

/// Changes the sample rate of a stream of audio, a piece at a time.
///
/// Each output sample is worked out from its place in the whole stream, in whole-number
/// arithmetic, never from where a piece happened to end. So the result is the same however the
/// stream is cut up, the joins between pieces cannot be heard, and nothing drifts.
struct StreamResampler: Sendable {
    let sourceRate: Double
    let targetRate: Double

    /// `up` output samples are made for every `down` input samples.
    private let up: Int
    private let down: Int
    /// Input samples used on each side of an output sample.
    private let reach: Int
    /// One row of `2 * reach` weights for each of the `up` places an output sample can fall
    /// between two input samples.
    private let weights: [Float]

    /// Input still needed for output not yet made.
    private var pending: [Float] = []
    /// Place in the whole stream of `pending[0]`.
    private var pendingStart = 0
    private var received = 0
    private var produced = 0

    /// Nil if either rate is not a usable number of samples per second. Rates are taken to the nearest hertz.
    init?(from sourceRate: Double, to targetRate: Double, config: BeatEngine.Config) {
        guard sourceRate.isFinite, targetRate.isFinite, sourceRate >= 1, targetRate >= 1,
              sourceRate <= Double(Int32.max), targetRate <= Double(Int32.max) else { return nil }
        let source = Int(sourceRate.rounded())
        let target = Int(targetRate.rounded())
        let common = Self.greatestCommonDivisor(source, target)
        self.sourceRate = sourceRate
        self.targetRate = targetRate
        up = target / common
        down = source / common

        // When the rate goes down, everything above the new upper limit has to be filtered out
        // first or it folds back as false low tones; that needs a proportionally wider curve.
        let cutoff = config.resamplerCutoff * min(1, Double(up) / Double(down))
        let reach = Int((Double(config.resamplerZeroCrossings) / cutoff).rounded(.up))
        self.reach = reach
        var weights: [Float] = []
        weights.reserveCapacity(up * 2 * reach)
        for place in 0..<up {
            let fraction = Double(place) / Double(up)
            let row = (0..<2 * reach).map { tap in
                Self.curve(at: fraction + Double(reach - 1 - tap), cutoff: cutoff, reach: Double(reach))
            }
            // Each row is made to add up to exactly 1, so a steady level stays the same level.
            let total = row.reduce(0, +)
            weights += row.map { Float($0 / total) }
        }
        self.weights = weights
    }

    /// Takes the next piece of the stream and returns every output sample that can now be made.
    /// The last few wait inside for the input that follows them.
    mutating func process(_ input: [Float]) -> [Float] {
        guard up != down else { return input }
        pending += input
        received += input.count
        // An output sample needs input up to `reach` samples past its own position, so only
        // those that sit before `received - reach` can be made yet.
        return makeOutput(upTo: outputLength(ofInput: received - reach))
    }

    /// Ends the stream: returns the output that was waiting for more input, and starts afresh.
    mutating func finish() -> [Float] {
        guard up != down else { return [] }
        let output = makeOutput(upTo: outputLength(ofInput: received))
        pending = []
        pendingStart = 0
        received = 0
        produced = 0
        return output
    }

    /// How many output samples sit before input position `count`: `count * up / down`, rounded up.
    private func outputLength(ofInput count: Int) -> Int {
        count > 0 ? (count * up + down - 1) / down : 0
    }

    private mutating func makeOutput(upTo end: Int) -> [Float] {
        var output: [Float] = []
        output.reserveCapacity(max(0, end - produced))
        while produced < end {
            // Output sample `produced` sits at input position `produced * down / up`:
            // `center` whole samples in, and `place` of `up` parts of the way to the next.
            let position = produced * down
            let center = position / up
            let place = position % up
            let row = place * 2 * reach
            var sum: Float = 0
            for tap in 0..<2 * reach {
                let index = center - reach + 1 + tap - pendingStart
                // Before the stream began and after it ended there is silence.
                if index >= 0, index < pending.count { sum += pending[index] * weights[row + tap] }
            }
            output.append(sum)
            produced += 1
        }
        // Input that no later output sample can reach is let go.
        let firstNeeded = produced * down / up - reach + 1
        let finished = min(pending.count, max(0, firstNeeded - pendingStart))
        pending.removeFirst(finished)
        pendingStart += finished
        return output
    }

    /// The interpolation curve: the ideal low-pass response, tapered smoothly to nothing at
    /// `reach` samples either side (a Blackman window) so that it can be finite.
    private static func curve(at offset: Double, cutoff: Double, reach: Double) -> Double {
        guard abs(offset) < reach else { return 0 }
        let angle = Double.pi * cutoff * offset
        let ideal = angle == 0 ? cutoff : cutoff * sin(angle) / angle
        let turn = Double.pi * offset / reach
        return ideal * (0.42 + 0.5 * cos(turn) + 0.08 * cos(2 * turn))
    }

    private static func greatestCommonDivisor(_ first: Int, _ second: Int) -> Int {
        var (larger, smaller) = (first, second)
        while smaller != 0 { (larger, smaller) = (smaller, larger % smaller) }
        return larger
    }
}
