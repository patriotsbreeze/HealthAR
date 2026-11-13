import Foundation

/// The beat as a pure function of a sample index.
///
/// Nothing here remembers anything: the same index always gives the same value. Every beat's
/// first sample is worked out from the beat number alone, so the spacing is exact to the sample
/// and cannot drift, however the audio system slices its blocks.
public struct ClickSynth: Sendable {
    /// Which of the two click sounds a beat uses.
    public enum Timbre: Sendable, Equatable, CaseIterable {
        /// Thin and high: the last compression fell short of the line.
        case tick
        /// Low and full: the last compression reached the line.
        case tock
    }

    /// Where a sample sits in the beat.
    public struct Position: Sendable, Equatable {
        /// Which beat the sample belongs to. 0 is the first.
        public let beat: Int
        /// Samples since that beat's first sample. 0 is the onset itself.
        public let offset: Int
    }

    /// Samples per second.
    public let sampleRate: Double
    /// Beats per minute.
    public let beatsPerMinute: Double
    /// Samples in one click. Every sample outside a click is exactly zero.
    public let clickSamples: Int

    private let samplesPerBeat: Double
    private let tick: ShapedClick
    private let tock: ShapedClick

    /// Makes the beat for a tempo. The sample rate and the shape of the clicks come from `config`.
    public init(beatsPerMinute: Double, config: BeatEngine.Config = .init()) {
        precondition(beatsPerMinute > 0 && beatsPerMinute.isFinite, "The beat needs a positive tempo.")
        precondition(config.sampleRate > 0 && config.sampleRate.isFinite,
                     "The beat needs a positive sample rate.")
        sampleRate = config.sampleRate
        self.beatsPerMinute = beatsPerMinute
        samplesPerBeat = 60 / beatsPerMinute * config.sampleRate
        // A click has to end before the next one begins, or the two would add up past full level.
        let wanted = Int((config.clickSeconds * config.sampleRate).rounded())
        clickSamples = max(1, min(wanted, Int(samplesPerBeat.rounded(.down))))
        tick = ShapedClick(config.tick, length: clickSamples, config: config)
        tock = ShapedClick(config.tock, length: clickSamples, config: config)
    }

    /// Index of the first sample of a beat: round(beat x 60 / tempo x sample rate).
    public func onsetSample(ofBeat beat: Int) -> Int {
        Int((Double(beat) * 60 / beatsPerMinute * sampleRate).rounded())
    }

    /// Which beat a sample belongs to and how far into it the sample is.
    public func position(ofSample index: Int) -> Position {
        var beat = Int((Double(index) / samplesPerBeat).rounded(.down))
        // Onsets are rounded to whole samples, so the estimate can be one beat out either way.
        while onsetSample(ofBeat: beat) > index { beat -= 1 }
        while onsetSample(ofBeat: beat + 1) <= index { beat += 1 }
        return Position(beat: beat, offset: index - onsetSample(ofBeat: beat))
    }

    /// How far through its beat a sample is, from 0 at the onset up to but never reaching 1.
    public func phase(atSample index: Int) -> Double {
        let position = position(ofSample: index)
        let beatLength = onsetSample(ofBeat: position.beat + 1) - onsetSample(ofBeat: position.beat)
        return Double(position.offset) / Double(beatLength)
    }

    /// The value of the sample `offset` samples after a beat's onset. Zero once the click is over.
    public func click(offset: Int, timbre: Timbre) -> Float {
        guard offset >= 0, offset < clickSamples else { return 0 }
        return Float((timbre == .tock ? tock : tick).value(at: offset))
    }

    /// The value of sample `index` when the beat it falls in uses `timbre`. Exactly zero when muted.
    public func sample(at index: Int, timbre: Timbre, muted: Bool) -> Float {
        muted ? 0 : click(offset: position(ofSample: index).offset, timbre: timbre)
    }

    /// The value of sample `index` when each beat has its own timbre, looked up by beat number.
    /// Exactly zero when muted.
    public func sample(at index: Int, muted: Bool, timbreOfBeat: (Int) -> Timbre) -> Float {
        guard !muted else { return 0 }
        let position = position(ofSample: index)
        return click(offset: position.offset, timbre: timbreOfBeat(position.beat))
    }
}

/// One click with its sums done ahead of time, so making a sample is a few multiplications.
private struct ShapedClick: Sendable {
    private let length: Double
    private let attackSamples: Double
    private let releaseSamples: Double
    private let decayPerSample: Double
    private let radiansPerSample: (Double, Double, Double)
    private var weights: (Double, Double, Double)

    init(_ voice: ClickVoice, length: Int, config: BeatEngine.Config) {
        let sampleRate = config.sampleRate
        self.length = Double(length)
        attackSamples = max(1, config.clickAttackSeconds * sampleRate)
        releaseSamples = max(1, config.clickReleaseSeconds * sampleRate)
        decayPerSample = 1 / max(1, voice.decaySeconds * sampleRate)
        let partials = [voice.first, voice.second, voice.third]
        let radians = partials.map { 2 * Double.pi * $0.hertz / sampleRate }
        radiansPerSample = (radians[0], radians[1], radians[2])
        // A partial at or above half the sample rate would fold back as a wrong, lower pitch.
        let levels = partials.map { $0.hertz > 0 && $0.hertz < sampleRate / 2 ? max(0, $0.level) : 0 }
        weights = (levels[0], levels[1], levels[2])

        // Scale so the loudest sample sits exactly at the configured level whatever the recipe:
        // both timbres then peak alike, and the level can be counted on when mixing with speech.
        let loudest = (0..<length).reduce(0) { max($0, abs(value(at: $1))) }
        let scale = loudest > 0 ? config.beatLevel / loudest : 0
        weights = (levels[0] * scale, levels[1] * scale, levels[2] * scale)
    }

    /// The sample `offset` samples after the strike. Only meaningful inside the click.
    func value(at offset: Int) -> Double {
        let elapsed = Double(offset)
        // The first sample is already above zero, so the onset is the first sample that sounds.
        let attack = min(1, (elapsed + 1) / attackSamples)
        let release = min(1, (length - elapsed) / releaseSamples)
        let ring = exp(-elapsed * decayPerSample)
        // Cosines start at their peak, which is what makes the click sound struck, not swelled.
        let partials = weights.0 * cos(radiansPerSample.0 * elapsed)
            + weights.1 * cos(radiansPerSample.1 * elapsed)
            + weights.2 * cos(radiansPerSample.2 * elapsed)
        return attack * release * ring * partials
    }
}
