import AVFoundation
import PlumbContracts
import Testing
@testable import PlumbSound

/// The real graph (beat source, players, mixer) rendered through AVAudioEngine's offline
/// manual rendering mode, with nothing swapped out.
@Suite("The beat through the real audio graph")
struct OfflineBeatTests {
    let synth = ClickSynth(beatsPerMinute: Targets.adult.beatPerMin)
    let sampleRate = 48_000

    func expectedOnset(_ beat: Int) -> Int {
        Int((Double(beat) * 60 / 110 * 48_000).rounded())
    }

    @Test("Ten seconds holds 19 clicks, each on the sample the tempo says")
    func tenSeconds() throws {
        let engine = offlineEngine()
        try engine.start()
        let audio = try engine.renderOffline(frameCount: 10 * sampleRate)
        #expect(audio.count == 480_000)

        // By energy: a click begins at the first sample above a thousandth of full scale that
        // follows a tenth of a second of quiet.
        let found = onsets(in: audio, louderThan: 0.001, afterQuiet: 4_800)
        // Beats 0...18 start inside ten seconds; beat 19 would start at 10.36 s.
        #expect(found.count == 19)
        // One sample period (1/48 000 s) is the finest step the rendered output can show.
        // The spacing is right to that step, measured from the first click with no drift.
        for (beat, onset) in found.enumerated() {
            #expect(onset == expectedOnset(beat), "beat \(beat) is off by \(onset - expectedOnset(beat)) samples")
        }
    }

    @Test("What the graph renders is the pure function, sample for sample")
    func graphMatchesPureFunction() throws {
        let engine = offlineEngine()
        try engine.start()
        let audio = try engine.renderOffline(frameCount: 3 * sampleRate)
        var worst: Float = 0
        for (index, sample) in audio.enumerated() {
            worst = max(worst, abs(sample - synth.sample(at: index, timbre: .tick, muted: false)))
        }
        #expect(worst < 0.000_001)
    }

    @Test("The audio system's block size makes no difference", arguments: [64, 333, 4_096] as [AVAudioFrameCount])
    func blockSizeIndependent(blockFrames: AVAudioFrameCount) throws {
        let reference = offlineEngine(blockFrames: 512)
        let other = offlineEngine(blockFrames: blockFrames)
        try reference.start()
        try other.start()
        #expect(try reference.renderOffline(frameCount: 100_000) == other.renderOffline(frameCount: 100_000))
    }

    @Test("The tempo comes from the targets")
    func tempoFromTargets() throws {
        let engine = offlineEngine(targets: Targets(beatPerMin: 120))
        try engine.start()
        let audio = try engine.renderOffline(frameCount: 2 * sampleRate)
        #expect(onsets(in: audio, louderThan: 0.001, afterQuiet: 4_800) == [0, 24_000, 48_000, 72_000])
    }

    @Test("A silent beat is exact silence and comes back in phase")
    func silentBeatKeepsPhase() throws {
        let engine = offlineEngine()
        engine.setBeatAudible(false)
        try engine.start()
        let silent = try engine.renderOffline(frameCount: 2 * sampleRate)
        #expect(silent.allSatisfy { $0 == 0 })

        engine.setBeatAudible(true)
        let heard = try engine.renderOffline(frameCount: 2 * sampleRate)
        // Clicks 4 to 7 fall in seconds 2 to 4, exactly where they would have been anyway.
        let found = onsets(in: heard, louderThan: 0.001, afterQuiet: 4_800).map { $0 + 2 * sampleRate }
        #expect(found == [4, 5, 6, 7].map(expectedOnset))
    }

    @Test("Silencing the beat mid-click lets that click finish; unsilencing mid-beat waits for the next")
    func clicksAreWhole() throws {
        let engine = offlineEngine()
        try engine.start()
        let midClick = expectedOnset(1) + 100
        var audio = try engine.renderOffline(frameCount: midClick)
        engine.setBeatAudible(false)
        audio += try engine.renderOffline(frameCount: expectedOnset(3) + 100 - midClick)
        engine.setBeatAudible(true)
        audio += try engine.renderOffline(frameCount: expectedOnset(5) - audio.count)

        // Beats 0 and 1 sound in full, 2 is silent, 3 stays silent (it had already begun), 4 sounds.
        let found = onsets(in: audio, louderThan: 0.001, afterQuiet: 4_800)
        #expect(found == [0, 1, 4].map(expectedOnset))
        let beatOneTail = audio[midClick..<expectedOnset(2)]
        #expect(beatOneTail.enumerated().allSatisfy {
            abs($1 - synth.sample(at: midClick + $0, timbre: .tick, muted: false)) < 0.000_001
        })
    }

    @Test("Stopping and starting again restarts the beat from phase 0")
    func restartFromPhaseZero() throws {
        let engine = offlineEngine()
        #expect(!engine.isRunning)
        try engine.start()
        #expect(engine.isRunning)
        // Stop part-way through beat 1, well after its click.
        _ = try engine.renderOffline(frameCount: 40_000)
        #expect(engine.beatPhase > 0.5)

        engine.stop()
        #expect(!engine.isRunning)
        #expect(engine.beatPhase == 0)

        try engine.start()
        let audio = try engine.renderOffline(frameCount: sampleRate)
        #expect(onsets(in: audio, louderThan: 0.001, afterQuiet: 4_800) == [0, 26_182])
        #expect(audio[0] == synth.sample(at: 0, timbre: .tick, muted: false))
    }

    @Test("Starting twice does not restart a running beat")
    func startIsIdempotent() throws {
        let engine = offlineEngine()
        try engine.start()
        _ = try engine.renderOffline(frameCount: 10_000)
        try engine.start()
        let audio = try engine.renderOffline(frameCount: 30_000)
        #expect(onsets(in: audio, louderThan: 0.001, afterQuiet: 4_800) == [26_182 - 10_000])
    }

    @Test("beatPhase follows the rendered position")
    func phaseFollowsTheBeat() throws {
        let engine = offlineEngine()
        #expect(engine.beatPhase == 0)
        try engine.start()
        var rendered = 0
        for step in [1, 511, 12_000, 13_000, 669, 1, 30_000] {
            _ = try engine.renderOffline(frameCount: step)
            rendered += step
            let phase = engine.beatPhase
            #expect(phase == synth.phase(atSample: rendered))
            #expect(phase >= 0 && phase < 1)
        }
    }

    @Test("markReached changes the next beat's timbre, never the one already sounding")
    func reachedPicksNextTimbre() throws {
        let engine = offlineEngine()
        try engine.start()
        // Say "reached" 100 samples into beat 1's click.
        let midClick = expectedOnset(1) + 100
        var audio = try engine.renderOffline(frameCount: midClick)
        engine.markReached(true)
        // Say "fell short" in the quiet after beat 3's click.
        let afterBeatThree = expectedOnset(3) + 10_000
        audio += try engine.renderOffline(frameCount: afterBeatThree - midClick)
        engine.markReached(false)
        audio += try engine.renderOffline(frameCount: expectedOnset(6) - afterBeatThree)

        let expected: [ClickSynth.Timbre] = [.tick, .tick, .tock, .tock, .tick, .tick]
        for (beat, timbre) in expected.enumerated() {
            let other: ClickSynth.Timbre = timbre == .tock ? .tick : .tock
            var errorAsExpected: Float = 0
            var errorAsOther: Float = 0
            for index in expectedOnset(beat)..<expectedOnset(beat) + synth.clickSamples {
                errorAsExpected = max(errorAsExpected, abs(audio[index] - synth.sample(at: index, timbre: timbre, muted: false)))
                errorAsOther = max(errorAsOther, abs(audio[index] - synth.sample(at: index, timbre: other, muted: false)))
            }
            #expect(errorAsExpected < 0.000_001, "beat \(beat) should be a \(timbre)")
            #expect(errorAsOther > 0.1, "beat \(beat) should not be a \(other)")
        }
    }

    @Test("stop() forgets the last markReached, so a new run opens on the tick")
    func stopForgetsReached() throws {
        let engine = offlineEngine()
        engine.markReached(true)
        try engine.start()
        let first = try engine.renderOffline(frameCount: synth.clickSamples)
        #expect(abs(first[500] - synth.click(offset: 500, timbre: .tock)) < 0.000_001)

        engine.stop()
        try engine.start()
        let second = try engine.renderOffline(frameCount: synth.clickSamples)
        #expect(abs(second[500] - synth.click(offset: 500, timbre: .tick)) < 0.000_001)
    }

    @Test("An engine made for the speaker refuses to be pulled by hand")
    func pullingNeedsAnOfflineEngine() {
        let engine = BeatEngine(targets: .adult, config: .init(), speaker: ToneSpeaker())
        #expect(throws: OfflinePullError.self) { try engine.renderOffline(frameCount: 16) }
    }
}
