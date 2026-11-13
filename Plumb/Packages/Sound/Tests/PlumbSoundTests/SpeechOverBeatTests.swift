import Foundation
import PlumbContracts
import Testing
@testable import PlumbSound

/// Cues, model speech and the beat sharing one output, heard through the real graph offline.
@Suite("Speech over the beat")
struct SpeechOverBeatTests {
    let sampleRate = 48_000
    let synth = ClickSynth(beatsPerMinute: 110)

    func expectedOnset(_ beat: Int) -> Int {
        Int((Double(beat) * 60 / 110 * 48_000).rounded())
    }

    /// An engine that has rendered its cues with the tone-per-cue stand-in voice and is running.
    func runningEngine(config: BeatEngine.Config = .init(), cueSeconds: Double = 0.6,
                       beatAudible: Bool = true) async throws -> BeatEngine {
        let engine = offlineEngine(config: config, speaker: ToneSpeaker(seconds: cueSeconds))
        await engine.prepare()
        engine.setBeatAudible(beatAudible)
        try engine.start()
        return engine
    }

    func amplitude(of cue: Cue, in audio: some Collection<Float>) -> Double {
        toneAmplitude(in: audio, hertz: ToneSpeaker.hertz(for: cue), sampleRate: 48_000)
    }

    // MARK: Ducking

    @Test("The beat drops to the configured share while a cue plays, and returns after",
          arguments: [0.5, 0.25])
    func ducking(duckedGain: Double) async throws {
        var config = BeatEngine.Config()
        config.duckedGain = duckedGain
        // The cue is made almost inaudible so that what is measured is the beat alone.
        config.cuePeak = 0.000_1
        let engine = try await runningEngine(config: config, cueSeconds: 1.5)

        var audio = try engine.renderOffline(frameCount: 2 * sampleRate)
        engine.speak(.good)
        audio += try engine.renderOffline(frameCount: 3 * sampleRate)

        func clickPeak(_ beat: Int) -> Float {
            peak(of: audio, from: expectedOnset(beat), count: synth.clickSamples)
        }
        // The cue runs from 2.0 s to 3.5 s. Beats 0 to 3 come before it, 4 to 6 fall wholly
        // inside it, and 7 onwards come after the tail and the ramp back up.
        let full = Float(config.beatLevel)
        for beat in 0...3 {
            #expect(abs(clickPeak(beat) - full) < 0.001, "beat \(beat) before the cue")
        }
        for beat in 4...6 {
            #expect(abs(Double(clickPeak(beat) / full) - duckedGain) < 0.01, "beat \(beat) under the cue")
        }
        for beat in 7...8 {
            #expect(abs(clickPeak(beat) - full) < 0.001, "beat \(beat) after the cue")
        }
    }

    @Test("The beat slides down and back up, never jumping")
    func duckingIsSmooth() async throws {
        var config = BeatEngine.Config()
        config.cuePeak = 0.000_1
        // One long click per beat turns the beat into a nearly continuous signal to watch the gain on.
        config.clickSeconds = 0.5
        config.tock.decaySeconds = 10
        let engine = try await runningEngine(config: config, cueSeconds: 0.2)
        engine.markReached(true)

        var audio = try engine.renderOffline(frameCount: 4_000)
        engine.speak(.faster)
        audio += try engine.renderOffline(frameCount: 8_000)

        // 30 ms at 48 000 Hz is 1440 samples, so the step from one sample to the next is tiny.
        let reference = ClickSynth(beatsPerMinute: 110, config: config)
        var gains: [Float] = []
        for index in 3_000..<8_000 {
            let dry = reference.sample(at: index, timbre: .tock, muted: false)
            if abs(dry) > 0.2 { gains.append(audio[index] / dry) }
        }
        #expect(abs((gains.first ?? 0) - 1) < 0.01)
        #expect(abs((gains.last ?? 0) - 0.5) < 0.01)
        #expect(zip(gains.dropFirst(), gains).allSatisfy { abs($0 - $1) < 0.02 })
    }

    @Test("The beat is ducked under model speech too, and released when it is stopped")
    func duckingUnderModelSpeech() async throws {
        let engine = try await runningEngine()
        // Two seconds of near-silent "speech", so only the beat is measured.
        engine.playModelAudio(pcm16: pcm16Data(sine(hertz: 700, seconds: 2, sampleRate: 24_000, amplitude: 0.000_1)),
                              sampleRate: 24_000)
        var audio = try engine.renderOffline(frameCount: expectedOnset(2) + 3_000)
        engine.stopModelAudio()
        audio += try engine.renderOffline(frameCount: sampleRate)

        let full = Float(BeatEngine.Config().beatLevel)
        #expect(abs(peak(of: audio, from: expectedOnset(1), count: synth.clickSamples) - 0.5 * full) < 0.01)
        #expect(abs(peak(of: audio, from: expectedOnset(2), count: synth.clickSamples) - 0.5 * full) < 0.01)
        #expect(abs(peak(of: audio, from: expectedOnset(3), count: synth.clickSamples) - full) < 0.001)
    }

    // MARK: Cues

    @Test("A cue is heard once, at cue level, and then it is over")
    func cuePlaysOnce() async throws {
        let engine = try await runningEngine(beatAudible: false)
        engine.speak(.slower)
        let during = try engine.renderOffline(frameCount: 24_000)
        // 0.6 s of cue ends at 28 800; listen again well after that.
        _ = try engine.renderOffline(frameCount: 12_000)
        let after = try engine.renderOffline(frameCount: 24_000)

        #expect(abs(amplitude(of: .slower, in: during) - BeatEngine.Config().cuePeak) < 0.03)
        #expect(after.allSatisfy { $0 == 0 })
    }

    @Test("Only \"push now\" cuts in on a cue that is playing")
    func onlyPushNowInterrupts() async throws {
        let engine = try await runningEngine(beatAudible: false)

        engine.speak(.pushHarder)
        _ = try engine.renderOffline(frameCount: 4_800)
        engine.speak(.faster)
        let stillHarder = try engine.renderOffline(frameCount: 9_600)
        #expect(amplitude(of: .pushHarder, in: stillHarder) > 0.5)
        #expect(amplitude(of: .faster, in: stillHarder) < 0.01)

        engine.speak(.pushNow)
        let nowPushNow = try engine.renderOffline(frameCount: 9_600)
        #expect(amplitude(of: .pushNow, in: nowPushNow) > 0.5)
        #expect(amplitude(of: .pushHarder, in: nowPushNow) < 0.01)
    }

    @Test("Asking for \"push now\" again while it plays does not start it over")
    func pushNowDoesNotRestartItself() async throws {
        let engine = try await runningEngine(beatAudible: false)
        engine.speak(.pushNow)
        _ = try engine.renderOffline(frameCount: 14_400)
        engine.speak(.pushNow)
        // The first one ends at 0.6 s. A restart at 0.3 s would still be sounding at 0.7 s.
        _ = try engine.renderOffline(frameCount: 16_800)
        let later = try engine.renderOffline(frameCount: 4_800)
        #expect(later.allSatisfy { $0 == 0 })
    }

    @Test("Once a cue has finished, the next one plays whatever it is")
    func nextCueAfterTheFirstEnds() async throws {
        let engine = try await runningEngine(beatAudible: false)
        engine.speak(.pushNow)
        // 0.6 s of cue plus the 0.12 s tail is 34 560 samples.
        _ = try engine.renderOffline(frameCount: 35_000)
        engine.speak(.good)
        let audio = try engine.renderOffline(frameCount: 9_600)
        #expect(amplitude(of: .good, in: audio) > 0.5)
    }

    @Test("Before prepare, and when speech fails, a cue is its tone pattern and never silence")
    func cueFallsBackToTones() async throws {
        let config = BeatEngine.Config()
        let unprepared = offlineEngine(speaker: ToneSpeaker())
        let failed = offlineEngine(speaker: FailingSpeaker(failure: .noAudio))
        await failed.prepare()

        for engine in [unprepared, failed] {
            engine.setBeatAudible(false)
            try engine.start()
            engine.speak(.pushNow)
            let tones = FallbackTones(config: config).clip(for: .pushNow)
            let audio = try engine.renderOffline(frameCount: tones.samples.count)
            // The player may start a few samples into the block; the notes are what matters.
            #expect(toneAmplitude(in: audio[..<4_320], hertz: config.fallbackHighHz, sampleRate: 48_000) > 0.5)
            #expect(engine.cueReport.fallbackCues == Cue.allCases)
        }
    }

    @Test("Nothing is spoken while the engine is stopped")
    func noSpeechWhileStopped() async throws {
        let engine = offlineEngine()
        await engine.prepare()
        engine.setBeatAudible(false)
        engine.speak(.pushNow)
        engine.playModelAudio(pcm16: pcm16Data(sine(hertz: 700, seconds: 1, sampleRate: 24_000)), sampleRate: 24_000)
        try engine.start()
        #expect(try engine.renderOffline(frameCount: 24_000).allSatisfy { $0 == 0 })
    }

    // MARK: Model speech

    @Test("Model speech is cut the moment a cue starts, and what arrives during the cue is dropped")
    func cueCutsModelSpeech() async throws {
        let engine = try await runningEngine(beatAudible: false)
        let modelHertz = 700.0
        let speech = pcm16Data(sine(hertz: modelHertz, seconds: 3, sampleRate: 24_000))
        func modelLevel(_ audio: some Collection<Float>) -> Double {
            toneAmplitude(in: audio, hertz: modelHertz, sampleRate: 48_000)
        }

        engine.playModelAudio(pcm16: speech, sampleRate: 24_000)
        let before = try engine.renderOffline(frameCount: 24_000)
        #expect(abs(modelLevel(before.dropFirst(2_400)) - 0.5) < 0.03)

        engine.speak(.good)
        let during = try engine.renderOffline(frameCount: 14_400)
        #expect(modelLevel(during) < 0.005)
        #expect(amplitude(of: .good, in: during) > 0.5)

        // More of the model's sentence arrives while the cue is still speaking.
        engine.playModelAudio(pcm16: speech, sampleRate: 24_000)
        _ = try engine.renderOffline(frameCount: 24_000)
        let after = try engine.renderOffline(frameCount: 24_000)
        // Neither the part that was cut nor the part that arrived mid-cue ever plays.
        #expect(after.allSatisfy { $0 == 0 })
    }

    @Test("Model speech queues in order, resumes after a cue, and stops on request")
    func modelSpeechQueuesAndStops() async throws {
        let engine = try await runningEngine(beatAudible: false)
        let low = pcm16Data(sine(hertz: 500, seconds: 0.25, sampleRate: 24_000))
        let high = pcm16Data(sine(hertz: 900, seconds: 0.25, sampleRate: 24_000))

        engine.playModelAudio(pcm16: low, sampleRate: 24_000)
        engine.playModelAudio(pcm16: high, sampleRate: 24_000)
        let first = try engine.renderOffline(frameCount: 12_000)
        let second = try engine.renderOffline(frameCount: 12_000)
        #expect(toneAmplitude(in: first.dropFirst(1_200).dropLast(1_200), hertz: 500, sampleRate: 48_000) > 0.45)
        #expect(toneAmplitude(in: second.dropFirst(1_200).dropLast(1_200), hertz: 900, sampleRate: 48_000) > 0.45)

        engine.speak(.faster)
        _ = try engine.renderOffline(frameCount: 36_000)
        engine.playModelAudio(pcm16: pcm16Data(sine(hertz: 500, seconds: 2, sampleRate: 24_000)), sampleRate: 24_000)
        let resumed = try engine.renderOffline(frameCount: 12_000)
        #expect(toneAmplitude(in: resumed.dropFirst(2_400), hertz: 500, sampleRate: 48_000) > 0.45)

        engine.stopModelAudio()
        #expect(try engine.renderOffline(frameCount: 12_000).allSatisfy { $0 == 0 })
    }

    @Test("Model speech plays at the right pitch and level whatever rate it arrives at",
          arguments: [16_000.0, 22_050.0, 24_000.0, 44_100.0, 48_000.0])
    func modelSpeechAtAnyRate(rate: Double) async throws {
        let engine = try await runningEngine(beatAudible: false)
        engine.playModelAudio(pcm16: pcm16Data(sine(hertz: 700, seconds: 1, sampleRate: rate)), sampleRate: rate)
        let audio = try engine.renderOffline(frameCount: 24_000)
        #expect(abs(toneAmplitude(in: audio.dropFirst(2_400), hertz: 700, sampleRate: 48_000) - 0.5) < 0.01)
    }

    @Test("Speech that arrives in many small pieces plays as one unbroken sound, even after a change of rate")
    func modelSpeechPiecesJoinCleanly() async throws {
        let engine = try await runningEngine(beatAudible: false)
        for rate in [24_000.0, 16_000.0] {
            // One second of tone, cut into pieces of uneven sizes as a network would deliver it.
            let whole = sine(hertz: 700, seconds: 1, sampleRate: rate)
            var start = 0
            for size in [480, 1, 2_399, 960, 37, 4_800].cycled(toCover: whole.count) {
                let end = min(whole.count, start + size)
                engine.playModelAudio(pcm16: pcm16Data(Array(whole[start..<end])), sampleRate: rate)
                start = end
            }
            let audio = try engine.renderOffline(frameCount: 48_000)
            let middle = audio[4_800..<43_200]
            let level = toneAmplitude(in: middle, hertz: 700, sampleRate: 48_000)
            let meanSquare = middle.reduce(0) { $0 + Double($1 * $1) } / Double(middle.count)
            #expect(abs(level - 0.5) < 0.01)
            // A pure tone's mean square is half its amplitude squared. A gap or a click at any
            // join would add energy that is not the tone.
            #expect(abs(meanSquare - level * level / 2) < 0.000_1, "at \(rate) Hz")
            _ = try engine.renderOffline(frameCount: 12_000)
        }
    }

    @Test("Model speech that cannot be played is ignored")
    func unusableModelSpeechIsIgnored() async throws {
        let engine = try await runningEngine(beatAudible: false)
        let speech = pcm16Data(sine(hertz: 700, seconds: 1, sampleRate: 24_000))
        engine.playModelAudio(pcm16: speech, sampleRate: 0)
        engine.playModelAudio(pcm16: speech, sampleRate: .nan)
        engine.playModelAudio(pcm16: speech, sampleRate: 1_000_000)
        engine.playModelAudio(pcm16: Data(), sampleRate: 24_000)
        engine.playModelAudio(pcm16: Data([7]), sampleRate: 24_000)
        #expect(try engine.renderOffline(frameCount: 24_000).allSatisfy { $0 == 0 })
    }

    // MARK: Speech made on the phone

    @Test("Speech made on the phone plays at full level on the model's lane, at the right pitch")
    func phoneSpeechPlays() async throws {
        let engine = try await runningEngine(beatAudible: false)
        engine.playSpeech(MonoClip(samples: sine(hertz: 700, seconds: 1, sampleRate: 22_050), sampleRate: 22_050))
        let audio = try engine.renderOffline(frameCount: 24_000)
        #expect(abs(toneAmplitude(in: audio.dropFirst(2_400), hertz: 700, sampleRate: 48_000) - 0.5) < 0.01)
    }

    @Test("Speech made on the phone never holds back a cue: a cue cuts it, and it is dropped while a cue plays")
    func phoneSpeechStaysUnderCues() async throws {
        let engine = try await runningEngine(beatAudible: false)
        let speech = MonoClip(samples: sine(hertz: 700, seconds: 3, sampleRate: 24_000), sampleRate: 24_000)
        func speechLevel(_ audio: some Collection<Float>) -> Double {
            toneAmplitude(in: audio, hertz: 700, sampleRate: 48_000)
        }

        engine.playSpeech(speech)
        _ = try engine.renderOffline(frameCount: 12_000)
        engine.speak(.slower)
        let during = try engine.renderOffline(frameCount: 14_400)
        #expect(speechLevel(during) < 0.005)
        #expect(amplitude(of: .slower, in: during) > 0.5)

        engine.playSpeech(speech)
        _ = try engine.renderOffline(frameCount: 24_000)
        #expect(try engine.renderOffline(frameCount: 24_000).allSatisfy { $0 == 0 })
    }

    @Test("Speech made on the phone that cannot be played is ignored")
    func unusablePhoneSpeechIsIgnored() async throws {
        let engine = try await runningEngine(beatAudible: false)
        let tone = sine(hertz: 700, seconds: 1, sampleRate: 24_000)
        engine.playSpeech(MonoClip(samples: tone, sampleRate: 0))
        engine.playSpeech(MonoClip(samples: tone, sampleRate: .nan))
        engine.playSpeech(MonoClip(samples: [], sampleRate: 24_000))
        #expect(try engine.renderOffline(frameCount: 24_000).allSatisfy { $0 == 0 })
    }
}

private extension Array where Element == Int {
    /// The sizes repeated in order until they add up to at least `total`.
    func cycled(toCover total: Int) -> [Int] {
        var sizes: [Int] = []
        var covered = 0
        while covered < total {
            let size = self[sizes.count % count]
            sizes.append(size)
            covered += size
        }
        return sizes
    }
}
