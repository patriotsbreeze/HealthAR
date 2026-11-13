import Foundation
import PlumbContracts
import Testing
@testable import PlumbSound

@Suite("Rendering the cues ahead of time")
struct CueRenderingTests {
    let config = BeatEngine.Config()

    @Test("The phrasebook says exactly what the brief says")
    func phrases() {
        #expect(CuePhrasebook.spokenText(for: .pushNow) == "Push now")
        #expect(CuePhrasebook.spokenText(for: .pushHarder) == "Push harder")
        #expect(CuePhrasebook.spokenText(for: .faster) == "Faster")
        #expect(CuePhrasebook.spokenText(for: .slower) == "Slower")
        #expect(CuePhrasebook.spokenText(for: .good) == "Good compressions")
    }

    /// Uses the Mac's own speech voice. A Mac with no voice, or one whose speech service does not
    /// answer, is not a failure: every cue must then be its tone pattern, and the report must say so.
    @Test("The system voice renders each phrase, or the cue falls back to its tones and says why")
    func systemVoice() async {
        let library = await CueLibrary.rendered(by: SystemCueSpeaker(config: config), config: config)
        let tones = FallbackTones(config: config)

        for cue in Cue.allCases {
            let clip = library.clip(for: cue)
            // Whichever path was taken, there is sound, at the engine's rate.
            #expect(!clip.samples.isEmpty)
            #expect(clip.peak > 0)
            #expect(clip.sampleRate == config.sampleRate)

            switch library.report.outcome(for: cue) {
            case .speech:
                #expect(clip != tones.clip(for: cue))
                #expect(abs(Double(clip.peak) - config.cuePeak) < 0.001)
                // A short phrase, with the dead air trimmed off: well under two seconds.
                #expect(clip.duration > 0.2 && clip.duration < 2)
                print("cue \(cue.rawValue): speech, \(clip.samples.count) samples, \(clip.duration) s")
            case .fallbackTone(let reason):
                #expect(clip == tones.clip(for: cue))
                #expect(!reason.isEmpty)
                print("cue \(cue.rawValue): fallback tones, because: \(reason)")
            }
        }
        #expect(library.report.allSpoken == library.report.fallbackCues.isEmpty)
    }

    @Test("Speech is trimmed, brought to the engine's rate and set to cue level")
    func speechIsReadied() async {
        // 0.6 s of tone at 22 050 Hz, as a voice would give it.
        let library = await CueLibrary.rendered(by: ToneSpeaker(), config: config)
        #expect(library.report.allSpoken)
        #expect(library.report.fallbackCues.isEmpty)
        for cue in Cue.allCases {
            let clip = library.clip(for: cue)
            #expect(library.report.outcome(for: cue) == .speech)
            #expect(clip.sampleRate == 48_000)
            #expect(abs(clip.duration - 0.6) < 0.005)
            #expect(abs(Double(clip.peak) - config.cuePeak) < 0.000_1)
            // Still the same pitch after the change of rate.
            let level = toneAmplitude(in: clip.samples, hertz: ToneSpeaker.hertz(for: cue), sampleRate: 48_000)
            #expect(abs(level - config.cuePeak) < 0.02)
        }
    }

    @Test("A phrase that fails becomes its tone pattern, and only that phrase")
    func oneFailureFallsBackAlone() async {
        let speaker = FailingSpeaker(failure: .noVoice(language: "en-US"), phrases: ["Faster"])
        let library = await CueLibrary.rendered(by: speaker, config: config)

        #expect(library.report.fallbackCues == [.faster])
        #expect(!library.report.allSpoken)
        #expect(library.report.outcome(for: .faster) == .fallbackTone(reason: "No voice is installed for en-US."))
        #expect(library.clip(for: .faster) == FallbackTones(config: config).clip(for: .faster))
        #expect(library.report.outcome(for: .slower) == .speech)
        #expect(speaker.timesAsked == 5)
    }

    @Test("A voice that returns silence counts as a failure")
    func silenceIsAFailure() async {
        struct SilentSpeaker: CueSpeaking {
            func render(_ text: String) async throws -> MonoClip {
                MonoClip(samples: [Float](repeating: 0, count: 10_000), sampleRate: 22_050)
            }
        }
        let library = await CueLibrary.rendered(by: SilentSpeaker(), config: config)
        #expect(library.report.fallbackCues == Cue.allCases)
        for cue in Cue.allCases {
            #expect(library.report.outcome(for: cue) == .fallbackTone(reason: "The speech service finished without any sound."))
            #expect(library.clip(for: cue).peak > 0)
        }
    }

    @Test("After one timeout the remaining phrases are not waited for")
    func timeoutStopsTrying() async {
        let speaker = FailingSpeaker(failure: .timedOut(seconds: 10))
        let library = await CueLibrary.rendered(by: speaker, config: config)

        #expect(speaker.timesAsked == 1)
        #expect(library.report.fallbackCues == Cue.allCases)
        #expect(library.report.outcome(for: .pushNow)
                == .fallbackTone(reason: "The speech service gave nothing within 10.0 seconds."))
        #expect(library.report.outcome(for: .good)
                == .fallbackTone(reason: "Not tried: the speech service had already stopped answering."))
    }

    @Test("Each cue's tone pattern is distinct, audible and short")
    func fallbackTonesAreDistinct() {
        let tones = FallbackTones(config: config)
        let patterns = Cue.allCases.map(FallbackTones.pattern)
        let clips = Cue.allCases.map(tones.clip)
        for first in Cue.allCases.indices {
            for second in Cue.allCases.indices where second > first {
                #expect(patterns[first] != patterns[second])
                #expect(clips[first] != clips[second])
            }
        }
        for clip in clips {
            #expect(clip.sampleRate == 48_000)
            #expect(abs(Double(clip.peak) - config.cuePeak) < 0.01)
            #expect(clip.duration > 0.2 && clip.duration < 0.8)
            // Faded in and out, so a note does not begin or end with a click.
            #expect(abs(clip.samples[0]) < 0.01 && abs(clip.samples[clip.samples.count - 1]) < 0.01)
        }
        // "Push now" is three pips at the high pitch and nothing at the low one.
        let pushNow = tones.clip(for: .pushNow).samples
        #expect(toneAmplitude(in: pushNow, hertz: config.fallbackHighHz, sampleRate: 48_000) > 0.3)
        #expect(toneAmplitude(in: pushNow, hertz: config.fallbackLowHz, sampleRate: 48_000) < 0.02)
    }

    @Test("The engine reports tones before prepare and speech after, and prepares only once")
    func engineReport() async {
        let speaker = FailingSpeaker(failure: .noAudio, phrases: ["Slower"])
        let engine = offlineEngine(speaker: speaker)
        #expect(engine.cueReport.fallbackCues == Cue.allCases)
        #expect(engine.cueReport.outcome(for: .good) == .fallbackTone(reason: "Speech has not been rendered yet."))

        await engine.prepare()
        #expect(engine.cueReport.fallbackCues == [.slower])
        #expect(engine.cueReport.outcome(for: .good) == .speech)

        // A second call, and two at once, change nothing and ask the voice for nothing more.
        await engine.prepare()
        async let again: Void = engine.prepare()
        async let andAgain: Void = engine.prepare()
        _ = await (again, andAgain)
        #expect(speaker.timesAsked == 5)
        #expect(engine.cueReport.fallbackCues == [.slower])
    }
}
