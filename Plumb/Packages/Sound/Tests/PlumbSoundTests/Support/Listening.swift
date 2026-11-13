import Foundation

// Small measuring tools the tests use to "listen" to rendered audio.

/// The first sample of every burst of sound: a sample louder than `threshold` that follows at
/// least `quietFrames` samples that were not.
func onsets(in samples: [Float], louderThan threshold: Float, afterQuiet quietFrames: Int) -> [Int] {
    var found: [Int] = []
    var lastLoud = -quietFrames - 1
    for (index, sample) in samples.enumerated() where abs(sample) > threshold {
        if index - lastLoud > quietFrames { found.append(index) }
        lastLoud = index
    }
    return found
}

/// The largest size any sample reaches in `count` samples starting at `start`.
func peak(of samples: [Float], from start: Int, count: Int) -> Float {
    samples[start..<min(samples.count, start + count)].reduce(0) { max($0, abs($1)) }
}

/// How strongly a steady tone at `hertz` is present, as the amplitude of that tone.
func toneAmplitude(in samples: some Collection<Float>, hertz: Double, sampleRate: Double) -> Double {
    var real = 0.0
    var imaginary = 0.0
    let step = 2 * Double.pi * hertz / sampleRate
    for (index, sample) in samples.enumerated() {
        real += Double(sample) * cos(step * Double(index))
        imaginary += Double(sample) * sin(step * Double(index))
    }
    return 2 * (real * real + imaginary * imaginary).squareRoot() / Double(max(1, samples.count))
}

/// Where the weight of a sound's spectrum sits, in hertz, from a plain discrete Fourier transform.
func spectralCentroid(of samples: [Float], sampleRate: Double) -> Double {
    let count = samples.count
    var weighted = 0.0
    var total = 0.0
    for bin in 1..<(count / 2) {
        var real = 0.0
        var imaginary = 0.0
        let step = 2 * Double.pi * Double(bin) / Double(count)
        for (index, sample) in samples.enumerated() {
            real += Double(sample) * cos(step * Double(index))
            imaginary -= Double(sample) * sin(step * Double(index))
        }
        let magnitude = (real * real + imaginary * imaginary).squareRoot()
        weighted += magnitude * Double(bin) * sampleRate / Double(count)
        total += magnitude
    }
    return weighted / total
}

/// A steady sine tone as samples.
func sine(hertz: Double, seconds: Double, sampleRate: Double, amplitude: Double = 0.5) -> [Float] {
    (0..<Int((seconds * sampleRate).rounded())).map {
        Float(amplitude * sin(2 * Double.pi * hertz * Double($0) / sampleRate))
    }
}

/// Samples as the 16-bit little-endian bytes a voice model would send.
func pcm16Data(_ samples: [Float]) -> Data {
    var data = Data(capacity: samples.count * 2)
    for sample in samples {
        let value = Int16((Double(sample) * 32_767).rounded()).littleEndian
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }
    return data
}
