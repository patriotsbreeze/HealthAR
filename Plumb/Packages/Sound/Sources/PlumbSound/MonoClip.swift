import Foundation

/// A stretch of single-channel audio as plain numbers, so it can cross threads and be compared.
public struct MonoClip: Sendable, Equatable {
    /// The samples, where 1 and -1 are the loudest the output can carry.
    public var samples: [Float]
    /// Samples per second.
    public var sampleRate: Double

    /// Makes a clip from samples and their rate.
    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    /// Length in seconds.
    public var duration: Double {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }

    /// The largest size any sample reaches. 0 for an empty or silent clip.
    public var peak: Float {
        samples.reduce(0) { max($0, abs($1)) }
    }
}

extension MonoClip {
    /// Reads 16-bit little-endian mono audio, the form voice models send. An odd last byte is dropped.
    init(pcm16: Data, sampleRate: Double) {
        let count = pcm16.count / 2
        let samples = pcm16.withUnsafeBytes { bytes in
            (0..<count).map { index in
                let value = bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)
                return Float(Int16(littleEndian: value)) / 32_768
            }
        }
        self.init(samples: samples, sampleRate: sampleRate)
    }

    /// The clip without the quiet stretch before its first and after its last audible sample.
    /// `floor` is a share of the clip's own peak; `padSeconds` of the quiet is kept at each end.
    func trimmingQuietEnds(floor: Double, padSeconds: Double) -> MonoClip {
        let threshold = peak * Float(floor)
        guard let first = samples.firstIndex(where: { abs($0) > threshold }),
              let last = samples.lastIndex(where: { abs($0) > threshold }) else { return self }
        let pad = Int((padSeconds * sampleRate).rounded())
        let start = max(0, first - pad)
        let end = min(samples.count, last + 1 + pad)
        return MonoClip(samples: Array(samples[start..<end]), sampleRate: sampleRate)
    }

    /// The same sound at another sample rate. Nil if either rate is unusable.
    func resampled(to rate: Double, config: BeatEngine.Config) -> MonoClip? {
        guard var resampler = StreamResampler(from: sampleRate, to: rate, config: config) else { return nil }
        return MonoClip(samples: resampler.process(samples) + resampler.finish(), sampleRate: rate)
    }

    /// The clip scaled so its loudest sample sits at `peak`. A silent clip is returned unchanged.
    func scaled(toPeak target: Double) -> MonoClip {
        let current = peak
        guard current > 0 else { return self }
        let gain = Float(target) / current
        return MonoClip(samples: samples.map { $0 * gain }, sampleRate: sampleRate)
    }
}
