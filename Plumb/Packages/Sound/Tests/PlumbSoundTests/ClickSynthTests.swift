import Foundation
import Testing
@testable import PlumbSound

@Suite("ClickSynth: the beat as a pure function")
struct ClickSynthTests {
    /// 48 000 Hz and 110 per minute: 26 181.81... samples per beat, so the rounding matters.
    let synth = ClickSynth(beatsPerMinute: 110)

    /// The onset the brief asks for, worked out here on its own and not taken from the synth.
    func expectedOnset(_ beat: Int, bpm: Double = 110, sampleRate: Double = 48_000) -> Int {
        Int((Double(beat) * 60 / bpm * sampleRate).rounded())
    }

    @Test("200 beats start exactly where the tempo says, with no drift")
    func onsetsAreExact() {
        #expect(synth.sampleRate == 48_000)
        let length = expectedOnset(200)
        let audio = (0..<length).map { synth.sample(at: $0, timbre: .tick, muted: false) }
        // Any sample that is not exactly zero counts, so this finds each click's very first sample.
        let found = onsets(in: audio, louderThan: 0, afterQuiet: synth.clickSamples)

        #expect(found.count == 200)
        for (beat, onset) in found.enumerated() {
            #expect(onset == expectedOnset(beat), "beat \(beat)")
        }
        // 26 181.81 does not fit a whole number of samples: gaps of 26 181 and 26 182 must alternate
        // so that the total stays right. A constant gap would drift by 0.8 samples every beat.
        let gaps = Set(zip(found.dropFirst(), found).map { $0 - $1 })
        #expect(gaps == [26_181, 26_182])
        #expect(found.last == 5_210_182)
    }

    @Test("Onsets stay exact at other tempos and sample rates",
          arguments: [(100.0, 48_000.0), (120.0, 48_000.0), (110.0, 44_100.0), (117.0, 22_050.0)])
    func onsetsAreExactElsewhere(bpm: Double, sampleRate: Double) {
        var config = BeatEngine.Config()
        config.sampleRate = sampleRate
        let synth = ClickSynth(beatsPerMinute: bpm, config: config)
        for beat in [0, 1, 2, 3, 50, 199, 10_000] {
            let onset = expectedOnset(beat, bpm: bpm, sampleRate: sampleRate)
            #expect(synth.onsetSample(ofBeat: beat) == onset)
            #expect(synth.position(ofSample: onset) == .init(beat: beat, offset: 0))
            #expect(synth.sample(at: onset, timbre: .tock, muted: false) != 0)
            if beat > 0 {
                #expect(synth.position(ofSample: onset - 1).beat == beat - 1)
                #expect(synth.sample(at: onset - 1, timbre: .tock, muted: false) == 0)
            }
        }
    }

    @Test("A click's energy stays inside its window", arguments: ClickSynth.Timbre.allCases)
    func energyIsConfined(timbre: ClickSynth.Timbre) {
        #expect(synth.clickSamples == 2_160) // 45 ms at 48 000 Hz
        for beat in [0, 1, 57, 199] {
            let onset = expectedOnset(beat)
            let next = expectedOnset(beat + 1)
            let inside = (onset..<onset + synth.clickSamples).map { synth.sample(at: $0, timbre: timbre, muted: false) }
            let outside = (onset + synth.clickSamples..<next).map { synth.sample(at: $0, timbre: timbre, muted: false) }
            let energyInside = inside.reduce(0) { $0 + Double($1 * $1) }
            #expect(energyInside > 1)
            #expect(outside.allSatisfy { $0 == 0 })
            // It ends by fading out, not by being cut off.
            #expect(abs(inside[inside.count - 1]) < 0.001)
        }
    }

    @Test("A click is short, struck fast, and peaks exactly at the configured level",
          arguments: ClickSynth.Timbre.allCases)
    func clickShape(timbre: ClickSynth.Timbre) {
        let level = Float(BeatEngine.Config().beatLevel)
        let click = (0..<synth.clickSamples).map { synth.click(offset: $0, timbre: timbre) }
        let loudest = click.map(abs).max() ?? 0
        #expect(abs(loudest - level) < 0.000_001)
        // Fast attack: the loudest sample comes within the first three milliseconds.
        let loudestIndex = click.firstIndex { abs($0) == loudest } ?? .max
        #expect(loudestIndex < 144)
        // Fast decay: nine tenths of the energy is gone within the first 25 ms.
        let energy = click.map { Double($0 * $0) }
        #expect(energy[..<1_200].reduce(0, +) > 0.9 * energy.reduce(0, +))
    }

    @Test("Tock is clearly lower and fuller than tick")
    func timbresDiffer() {
        let tick = (0..<synth.clickSamples).map { synth.click(offset: $0, timbre: .tick) }
        let tock = (0..<synth.clickSamples).map { synth.click(offset: $0, timbre: .tock) }
        let tickCentroid = spectralCentroid(of: tick, sampleRate: synth.sampleRate)
        let tockCentroid = spectralCentroid(of: tock, sampleRate: synth.sampleRate)

        #expect(tickCentroid > 2 * tockCentroid, "tick \(tickCentroid) Hz, tock \(tockCentroid) Hz")
        #expect(tickCentroid > 2_000)
        #expect(tockCentroid < 1_500)
        // Fuller: the tock carries more energy at the same peak level.
        let tickEnergy = tick.reduce(0) { $0 + Double($1 * $1) }
        let tockEnergy = tock.reduce(0) { $0 + Double($1 * $1) }
        #expect(tockEnergy > 1.5 * tickEnergy)
    }

    @Test("Muting gives exact silence, and the beat comes back in phase")
    func muting() {
        let threeBeats = expectedOnset(3)
        #expect((0..<threeBeats).allSatisfy { synth.sample(at: $0, timbre: .tock, muted: true) == 0 })

        // Muted from the start until part-way through beat 4, then heard again.
        let unmuteAt = expectedOnset(4) + 9_000
        let length = expectedOnset(8)
        let audio = (0..<length).map { synth.sample(at: $0, timbre: .tick, muted: $0 < unmuteAt) }
        let found = onsets(in: audio, louderThan: 0, afterQuiet: synth.clickSamples)
        #expect(found == [5, 6, 7].map { expectedOnset($0) })
    }

    @Test("Each beat takes the timbre it is given")
    func timbrePerBeat() {
        let evenBeatsAreTocks: (Int) -> ClickSynth.Timbre = { $0.isMultiple(of: 2) ? .tock : .tick }
        for beat in 0..<6 {
            let timbre = evenBeatsAreTocks(beat)
            let other: ClickSynth.Timbre = timbre == .tock ? .tick : .tock
            for offset in [0, 1, 40, 500, 2_000] {
                let index = expectedOnset(beat) + offset
                let value = synth.sample(at: index, muted: false, timbreOfBeat: evenBeatsAreTocks)
                #expect(value == synth.click(offset: offset, timbre: timbre))
                #expect(value != synth.click(offset: offset, timbre: other))
            }
        }
        #expect(synth.sample(at: 0, muted: true, timbreOfBeat: evenBeatsAreTocks) == 0)
    }

    @Test("Phase runs from 0 at the click up to, but never reaching, 1")
    func phase() {
        for beat in [0, 1, 2, 77] {
            let onset = expectedOnset(beat)
            let next = expectedOnset(beat + 1)
            #expect(synth.phase(atSample: onset) == 0)
            #expect(abs(synth.phase(atSample: (onset + next) / 2) - 0.5) < 0.0001)
            let last = synth.phase(atSample: next - 1)
            #expect(last < 1 && last > 0.9999)
        }
    }

    @Test("The same index always gives the same value")
    func pure() {
        let copy = synth
        for index in stride(from: 0, to: 200_000, by: 37) {
            #expect(synth.sample(at: index, timbre: .tock, muted: false) == copy.sample(at: index, timbre: .tock, muted: false))
        }
    }

    @Test("A click longer than a beat is shortened so clicks never overlap")
    func clickNeverOverlapsTheNext() {
        var config = BeatEngine.Config()
        config.clickSeconds = 5
        let synth = ClickSynth(beatsPerMinute: 110, config: config)
        #expect(synth.clickSamples == 26_181)
    }

    @Test("A partial above half the sample rate is left out instead of aliasing")
    func noAliasing() {
        var config = BeatEngine.Config()
        config.sampleRate = 8_000
        // Both of the tick's partials (2500 and 3750 Hz) fit under 4000 Hz; move one above it.
        config.tick.second.hertz = 5_000
        let synth = ClickSynth(beatsPerMinute: 110, config: config)
        let click = (0..<synth.clickSamples).map { synth.click(offset: $0, timbre: .tick) }
        // 5000 Hz sampled at 8000 Hz would show up at 3000 Hz.
        #expect(toneAmplitude(in: click, hertz: 3_000, sampleRate: 8_000) < 0.01)
        #expect(toneAmplitude(in: click, hertz: 2_500, sampleRate: 8_000) > 0.05)
    }
}
