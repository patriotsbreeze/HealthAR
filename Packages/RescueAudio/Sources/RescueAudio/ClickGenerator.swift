import Foundation

/// The CPR beat: a click on every beat at 110/min and a softer one just after.
///
/// Output is a pure function of an integer sample counter. Each onset is computed from its beat
/// number rather than from the previous onset, so rounding error can't accumulate.
/// Contains no references and `render` doesn't allocate, so it is safe on the audio thread.
public struct ClickGenerator: Sendable {
    public static let beatsPerMinute = 110
    /// 60/110 s, about 545.45 ms.
    public static let beatInterval = 60.0 / Double(beatsPerMinute)
    public static let softClickDelay = 0.12
    public static let softClickGain = 0.45

    private static let clickDuration = 0.025
    private static let attack = 0.0005
    private static let decay = 0.007
    private static let gain = 0.8
    // Mid-frequency, where phone speakers are loud and voice processing doesn't filter it out.
    private static let lowHertz = 1400.0
    private static let highHertz = 2600.0

    public let sampleRate: Int
    public private(set) var sampleCounter = 0

    private let clickLength: Int
    private let softOffset: Int

    public init(sampleRate: Int) {
        precondition(sampleRate > 0)
        self.sampleRate = sampleRate
        clickLength = Int(Self.clickDuration * Double(sampleRate))
        softOffset = Int(Self.softClickDelay * Double(sampleRate))
    }

    /// The sample on which beat `index` starts: the ideal grid position, rounded to nearest.
    public func beatOnset(_ index: Int) -> Int {
        (index * 60 * sampleRate + Self.beatsPerMinute / 2) / Self.beatsPerMinute
    }

    public mutating func reset() {
        sampleCounter = 0
    }

    public mutating func render(into output: UnsafeMutablePointer<Float>, frameCount: Int) {
        var beat = beatContaining(sampleCounter)
        var onset = beatOnset(beat)
        var nextOnset = beatOnset(beat + 1)
        // Not `for in`: unoptimized, that creates generic metadata, which can allocate.
        var frame = 0
        while frame < frameCount {
            let position = sampleCounter + frame
            if position == nextOnset {
                beat += 1
                onset = nextOnset
                nextOnset = beatOnset(beat + 1)
            }
            output[frame] = sample(sinceOnset: position - onset)
            frame += 1
        }
        sampleCounter += frameCount
    }

    private func beatContaining(_ position: Int) -> Int {
        let beat = position * Self.beatsPerMinute / (60 * sampleRate)
        if beatOnset(beat) > position { return beat - 1 }
        return beatOnset(beat + 1) <= position ? beat + 1 : beat
    }

    private func sample(sinceOnset offset: Int) -> Float {
        if offset < clickLength { return Float(Self.gain * click(offset)) }
        let softPosition = offset - softOffset
        if softPosition >= 0, softPosition < clickLength {
            return Float(Self.gain * Self.softClickGain * click(softPosition))
        }
        return 0
    }

    private func click(_ offset: Int) -> Double {
        let time = Double(offset) / Double(sampleRate)
        let rise = min(1, Double(offset + 1) / (Self.attack * Double(sampleRate)))
        let fall = 1 - Double(offset) / Double(clickLength)
        let tone = 0.7 * cos(2 * .pi * Self.lowHertz * time) + 0.3 * cos(2 * .pi * Self.highHertz * time)
        return rise * fall * exp(-time / Self.decay) * tone
    }
}
