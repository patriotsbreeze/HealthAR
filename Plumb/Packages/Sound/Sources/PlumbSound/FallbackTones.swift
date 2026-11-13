import Foundation
import PlumbContracts

/// The short tone patterns that stand in for cues whose speech could not be rendered.
/// Each cue has its own pattern, so they can still be told apart with no words at all.
public struct FallbackTones: Sendable, Equatable {
    /// One note of a pattern: low or high, short or long.
    public enum Note: Sendable, Equatable {
        /// A short note at the low pitch.
        case lowShort
        /// A long note at the low pitch.
        case lowLong
        /// A short note at the high pitch.
        case highShort
        /// A long note at the high pitch.
        case highLong
    }

    private let config: BeatEngine.Config

    /// Makes the tones with the pitches, lengths and level set in `config`.
    public init(config: BeatEngine.Config = .init()) {
        self.config = config
    }

    /// The notes that stand for a cue. No two cues share a pattern.
    public static func pattern(for cue: Cue) -> [Note] {
        switch cue {
        // Three urgent pips.
        case .pushNow: [.highShort, .highShort, .highShort]
        // Falls and leans on the low note, like a push down.
        case .pushHarder: [.highShort, .lowLong]
        // Busy and quick.
        case .faster: [.lowShort, .highShort, .lowShort, .highShort]
        // Two unhurried notes.
        case .slower: [.lowLong, .lowLong]
        // Rises and rests.
        case .good: [.lowShort, .highLong]
        }
    }

    /// The cue's pattern as audio at the engine's sample rate, peaking at the same level as speech.
    public func clip(for cue: Cue) -> MonoClip {
        let notes = Self.pattern(for: cue)
        let gap = [Float](repeating: 0, count: Int((config.fallbackGapSeconds * config.sampleRate).rounded()))
        var samples: [Float] = []
        for (index, note) in notes.enumerated() {
            if index > 0 { samples += gap }
            samples += tone(note)
        }
        return MonoClip(samples: samples, sampleRate: config.sampleRate)
    }

    private func tone(_ note: Note) -> [Float] {
        let hertz: Double
        let seconds: Double
        switch note {
        case .lowShort: (hertz, seconds) = (config.fallbackLowHz, config.fallbackShortSeconds)
        case .lowLong: (hertz, seconds) = (config.fallbackLowHz, config.fallbackLongSeconds)
        case .highShort: (hertz, seconds) = (config.fallbackHighHz, config.fallbackShortSeconds)
        case .highLong: (hertz, seconds) = (config.fallbackHighHz, config.fallbackLongSeconds)
        }
        let count = Int((seconds * config.sampleRate).rounded())
        let edge = max(1, config.fallbackEdgeSeconds * config.sampleRate)
        return (0..<count).map { index in
            let position = Double(index)
            // Fading each end in and out keeps a note from starting or stopping with a click.
            let fadeIn = min(1, (position + 1) / edge)
            let fadeOut = min(1, (Double(count) - position) / edge)
            let wave = sin(2 * Double.pi * hertz * position / config.sampleRate)
            return Float(config.cuePeak * fadeIn * fadeOut * wave)
        }
    }
}
